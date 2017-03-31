#ifndef SKYNET_IMP_H
#define SKYNET_IMP_H

struct skynet_config {
	int thread;					// 线程数
	int harbor;					// harbor id
	int profile;
	const char * daemon;		// daemon name
	const char * module_path;	// cpath，各个service的so文件目录
	const char * bootstrap;		// 启动服务
	const char * logger;		// logservice 参数，它决定了skynet_error输出到哪里，如果没有则输出到标准输出中
	const char * logservice;	// log的服务，见config.userlog，默认配置是service_logger，可以配置成snlua
};

#define THREAD_WORKER 0
#define THREAD_MAIN 1
#define THREAD_SOCKET 2
#define THREAD_TIMER 3
#define THREAD_MONITOR 4

void skynet_start(struct skynet_config * config);

#endif
