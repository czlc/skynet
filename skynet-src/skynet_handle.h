#ifndef SKYNET_CONTEXT_HANDLE_H
#define SKYNET_CONTEXT_HANDLE_H

#include <stdint.h>

// reserve high 8 bits for remote id
#define HANDLE_MASK 0xffffff
#define HANDLE_REMOTE_SHIFT 24

struct skynet_context;

/* 注册一个ctx，并返回其句柄 */
uint32_t skynet_handle_register(struct skynet_context *);
int skynet_handle_retire(uint32_t handle);

/* 根据 handle 获得一个 ctx，会增加其引用计数，所以获得的对象不会被其它线程释放
** 但是要访问其中的数据还得加锁
*/
struct skynet_context * skynet_handle_grab(uint32_t handle);

/* 关闭所有服务 */
void skynet_handle_retireall();

uint32_t skynet_handle_findname(const char * name);
const char * skynet_handle_namehandle(uint32_t handle, const char *name);

void skynet_handle_init(int harbor);

#endif
