#ifndef SKYNET_TIMER_H
#define SKYNET_TIMER_H

#include <stdint.h>

/* 添加一个计时器，时间到了向handle发送session消息, time为触发时间(centisecond) */
int skynet_timeout(uint32_t handle, int time, int session);

/* 周期更新时间 */
void skynet_updatetime(void);

/* 获得skynet启动时间(centisecond) */
uint32_t skynet_starttime(void);
uint64_t skynet_thread_time(void);	// for profile, in micro second

void skynet_timer_init(void);

#endif
