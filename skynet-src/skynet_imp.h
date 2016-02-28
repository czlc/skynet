#ifndef SKYNET_IMP_H
#define SKYNET_IMP_H

struct skynet_config {
	int thread;					// 线程数
	int harbor;					// harbor id
	const char * daemon;		// daemon name
	const char * module_path;	// cpath，各个service的so文件目录
	const char * bootstrap;		// 启动服务
	const char * logger;		// log文件名
	const char * logservice;
};

#define THREAD_WORKER 0
#define THREAD_MAIN 1
#define THREAD_SOCKET 2
#define THREAD_TIMER 3
#define THREAD_MONITOR 4

void skynet_start(struct skynet_config * config);

#endif
