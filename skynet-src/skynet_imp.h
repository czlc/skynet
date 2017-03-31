#ifndef SKYNET_IMP_H
#define SKYNET_IMP_H

struct skynet_config {
	int thread;					// �߳���
	int harbor;					// harbor id
	int profile;
	const char * daemon;		// daemon name
	const char * module_path;	// cpath������service��so�ļ�Ŀ¼
	const char * bootstrap;		// ��������
	const char * logger;		// logservice ��������������skynet_error�����������û�����������׼�����
	const char * logservice;	// log�ķ��񣬼�config.userlog��Ĭ��������service_logger���������ó�snlua
};

#define THREAD_WORKER 0
#define THREAD_MAIN 1
#define THREAD_SOCKET 2
#define THREAD_TIMER 3
#define THREAD_MONITOR 4

void skynet_start(struct skynet_config * config);

#endif
