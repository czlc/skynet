#ifndef SKYNET_SERVER_H
#define SKYNET_SERVER_H

#include <stdint.h>
#include <stdlib.h>

struct skynet_context;
struct skynet_message;
struct skynet_monitor;

struct skynet_context * skynet_context_new(const char * name, const char * parm);
/* 因为外界获得此 ctx 增加引用计数 */
void skynet_context_grab(struct skynet_context *);
/* 保留此context，使其不会被释放，非常特别 */
void skynet_context_reserve(struct skynet_context *ctx);

/* 基于引用计数的释放 */
struct skynet_context * skynet_context_release(struct skynet_context *);
uint32_t skynet_context_handle(struct skynet_context *);
int skynet_context_push(uint32_t handle, struct skynet_message *message);
/* 向context代表的服务发送一条消息 */
void skynet_context_send(struct skynet_context * context, void * msg, size_t sz, uint32_t source, int type, int session);
int skynet_context_newsession(struct skynet_context *);
struct message_queue * skynet_context_message_dispatch(struct skynet_monitor *, struct message_queue *, int weight);	// return next queue
int skynet_context_total();
void skynet_context_dispatchall(struct skynet_context * context);	// for skynet_error output before exit

void skynet_context_endless(uint32_t handle);	// for monitor

void skynet_globalinit(void);
void skynet_globalexit(void);
void skynet_initthread(int m);

void skynet_profile_enable(int enable);

#endif
