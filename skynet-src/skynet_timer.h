#ifndef SKYNET_TIMER_H
#define SKYNET_TIMER_H

#include <stdint.h>

/* ���һ����ʱ����ʱ�䵽����handle����session��Ϣ, timeΪ����ʱ��(centisecond) */
int skynet_timeout(uint32_t handle, int time, int session);

/* ���ڸ���ʱ�� */
void skynet_updatetime(void);

/* ���skynet����ʱ��(centisecond) */
uint32_t skynet_starttime(void);
uint64_t skynet_thread_time(void);	// for profile, in micro second

void skynet_timer_init(void);

#endif
