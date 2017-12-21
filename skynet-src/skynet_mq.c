#include "skynet.h"
#include "skynet_mq.h"
#include "skynet_handle.h"
#include "spinlock.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdbool.h>

#define DEFAULT_QUEUE_SIZE 64
#define MAX_GLOBAL_MQ 0x10000

// 0 means mq is not in global mq.
// 1 means mq is in global mq , or the message is dispatching.

#define MQ_IN_GLOBAL 1
#define MQ_OVERLOAD 1024

// 轮询处理global_queue中每个message_queue
// 1.从global_queue中pop一个ctx的message_queue
// 2.根据权重不同，处理一个或者多个此message_queue中的skynet_message
// 3.如果此message_queue中还有剩余的skynet_message，则把此message_queue
//   重新push到global_queue中，否则直到message_queue有新的skynet_message
//   的时候再重新把此message_queue push到 global_queue中来
struct message_queue {
	struct spinlock lock;	// 多个线程可能同时对queue做操作
	uint32_t handle;		// 消息队列所属的服务句柄
	int cap;				// queue size
	int head;				// 循环队列head
	int tail;				// 循环队列tail
	int release;
	int in_global;
	int overload;
	int overload_threshold;	// 过载临界点
	struct skynet_message *queue;	// 循环队列用数组的方式实现
	struct message_queue *next;		// 维系它在全局队列中的关系
};
// 它可能同时被global_queue和skynet_context引用所以删除的时候需要注意 http://blog.codingnow.com/2012/08/skynet_bug.html

// 全局队列，worker从head取，新来的压入tail
struct global_queue {
	struct message_queue *head;
	struct message_queue *tail;
	struct spinlock lock;
};
// head和tail只增不减，通过GP来取得在数组queue中的位置

static struct global_queue *Q = NULL;

/* 向全局队列中压入一个消息队列 */
void 
skynet_globalmq_push(struct message_queue * queue) {
	struct global_queue *q= Q;

	// 要求线程安全
	SPIN_LOCK(q)
	assert(queue->next == NULL);	// 必须是 Q 之外的队列
	if(q->tail) {
		q->tail->next = queue;
		q->tail = queue;
	} else {
		q->head = q->tail = queue;
	}
	SPIN_UNLOCK(q)
}

/* 从全局队列中弹出第一个消息队列，这样的话每个消息队列(ctx)，只能被一个线程处理 */
struct message_queue * 
skynet_globalmq_pop() {
	struct global_queue *q = Q;

	SPIN_LOCK(q)
	struct message_queue *mq = q->head;
	if(mq) {
		q->head = mq->next;
		if(q->head == NULL) {
			assert(mq == q->tail);
			q->tail = NULL;
		}
		mq->next = NULL;
	}
	SPIN_UNLOCK(q)

	return mq;
}

/* 为指定服务创建一个消息队列 */
struct message_queue * 
skynet_mq_create(uint32_t handle) {
	struct message_queue *q = skynet_malloc(sizeof(*q));
	q->handle = handle;
	q->cap = DEFAULT_QUEUE_SIZE;
	q->head = 0;
	q->tail = 0;
	SPIN_INIT(q)
	// When the queue is create (always between service create and service init) ,
	// set in_global flag to avoid push it to global queue (因为别的服务可能这个时候给它发送消息，在它之前已经为其注册了handle，所以别人可能向它发送消息).
	// If the service init success, skynet_context_new will call skynet_globalmq_push to push it to global queue.
	q->in_global = MQ_IN_GLOBAL;
	q->release = 0;
	q->overload = 0;
	q->overload_threshold = MQ_OVERLOAD;
	q->queue = skynet_malloc(sizeof(struct skynet_message) * q->cap);
	q->next = NULL;

	return q;
}

static void 
_release(struct message_queue *q) {
	assert(q->next == NULL);
	SPIN_DESTROY(q)
	skynet_free(q->queue);
	skynet_free(q);
}

uint32_t 
skynet_mq_handle(struct message_queue *q) {
	return q->handle;
}

int
skynet_mq_length(struct message_queue *q) {
	int head, tail,cap;

	SPIN_LOCK(q)
	head = q->head;
	tail = q->tail;
	cap = q->cap;
	SPIN_UNLOCK(q)
	
	if (head <= tail) {
		return tail - head;
	}
	return tail + cap - head;
}

/* 获得当前过载量，只有超过过载临界点才会记录一次，且连续记录是翻倍的量，即第一次记录n，清空前第二次需要2n才会记录 */ 
int
skynet_mq_overload(struct message_queue *q) {
	if (q->overload) {
		int overload = q->overload;
		q->overload = 0;
		return overload;
	} 
	return 0;
}

/* 从消息队列中弹出一条消息 */
int
skynet_mq_pop(struct message_queue *q, struct skynet_message *message) {
	int ret = 1;
	SPIN_LOCK(q)

	if (q->head != q->tail) {
		*message = q->queue[q->head++];
		ret = 0;
		int head = q->head;
		int tail = q->tail;
		int cap = q->cap;

		// head 偏移超过范围了，说明得从头开始
		if (head >= cap) {
			q->head = head = 0;
		}
		int length = tail - head;
		if (length < 0) {
			length += cap;
		}
		while (length > q->overload_threshold) {
			q->overload = length;
			q->overload_threshold *= 2;
		}
	} else {
		// reset overload_threshold when queue is empty
		q->overload_threshold = MQ_OVERLOAD;
	}

	if (ret) {
		q->in_global = 0;
	}
	
	SPIN_UNLOCK(q)

	return ret;
}

static void
expand_queue(struct message_queue *q) {
	struct skynet_message *new_queue = skynet_malloc(sizeof(struct skynet_message) * q->cap * 2);
	int i;
	for (i=0;i<q->cap;i++) {
		new_queue[i] = q->queue[(q->head + i) % q->cap];
	}
	q->head = 0;
	q->tail = q->cap;
	q->cap *= 2;
	
	skynet_free(q->queue);
	q->queue = new_queue;
}

/* 向某个服务的消息队列末尾压入一条消息，如果消息队列不在global queue，则将此队列压入进去，避免没有消息的时候也空转 */
void 
skynet_mq_push(struct message_queue *q, struct skynet_message *message) {
	assert(message);
	SPIN_LOCK(q)

	q->queue[q->tail] = *message;
	if (++ q->tail >= q->cap) {
		q->tail = 0;
	}

	if (q->head == q->tail) {
		expand_queue(q);
	}

	if (q->in_global == 0) {
		q->in_global = MQ_IN_GLOBAL;
		skynet_globalmq_push(q);
	}
	
	SPIN_UNLOCK(q)
}

void 
skynet_mq_init() {
	struct global_queue *q = skynet_malloc(sizeof(*q));
	memset(q,0,sizeof(*q));
	SPIN_INIT(q);
	Q=q;
}

// 删除message_queue step1：
// 删除ctx的时候调用,因为还有可能被global_queue引用，所以不能直接删除
void 
skynet_mq_mark_release(struct message_queue *q) {
	SPIN_LOCK(q)
	assert(q->release == 0);
	q->release = 1;
	if (q->in_global != MQ_IN_GLOBAL) {
		skynet_globalmq_push(q);
	}
	SPIN_UNLOCK(q)
}

static void
_drop_queue(struct message_queue *q, message_drop drop_func, void *ud) {
	struct skynet_message msg;
	while(!skynet_mq_pop(q, &msg)) {
		drop_func(&msg, ud);
	}
	_release(q);
}

// 删除message_queue step2：
// 从global_queue pop出来dispatch消息的时候调用
// 如果q->release == 1表明message_queue对应的ctx已经被删除，所以ctx已经不再持有对message_queue的引用，
// 此时message_queue已经从global_queue弹出，因此可以真正删除此message_queue
// 如果q->release == 0表面ctx还在，还不能删除
void 
skynet_mq_release(struct message_queue *q, message_drop drop_func, void *ud) {
	SPIN_LOCK(q)
	
	if (q->release) {
		SPIN_UNLOCK(q)
		_drop_queue(q, drop_func, ud);
	} else {
		skynet_globalmq_push(q);
		SPIN_UNLOCK(q)
	}
}
