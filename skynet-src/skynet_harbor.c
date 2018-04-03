#include "skynet.h"
#include "skynet_harbor.h"
#include "skynet_server.h"
#include "skynet_mq.h"
#include "skynet_handle.h"

#include <string.h>
#include <stdio.h>
#include <assert.h>

static struct skynet_context * REMOTE = 0;	/* harbor 服务 */
static unsigned int HARBOR = ~0;

static inline int
invalid_type(int type) {
	return type != PTYPE_SYSTEM && type != PTYPE_HARBOR;
}

/* 发送本节点的HARBOR去，由它转发到其它节点去 */
void 
skynet_harbor_send(struct remote_message *rmsg, uint32_t source, int session) {
	assert(invalid_type(rmsg->type) && REMOTE);
	skynet_context_send(REMOTE, rmsg, sizeof(*rmsg) , source, PTYPE_SYSTEM , session);
}

int 
skynet_harbor_message_isremote(uint32_t handle) {
	assert(HARBOR != ~0);
	int h = (handle & ~HANDLE_MASK);
	return h != HARBOR && h !=0;	// h == HARBOR说明是本结点的harbor id，所以不用远程消息
}

void
skynet_harbor_init(int harbor) {
	HARBOR = (unsigned int)harbor << HANDLE_REMOTE_SHIFT;
}

/* 注册harbor服务 */
void
skynet_harbor_start(void *ctx) {
	// the HARBOR must be reserved to ensure the pointer is valid.
	// It will be released at last by calling skynet_harbor_exit
	skynet_context_reserve(ctx);
	REMOTE = ctx;
}

void
skynet_harbor_exit() {
	struct skynet_context * ctx = REMOTE;
	REMOTE= NULL;
	if (ctx) {
		skynet_context_release(ctx);
	}
}
