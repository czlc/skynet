#ifndef SKYNET_H
#define SKYNET_H

#include "skynet_malloc.h"

#include <stddef.h>
#include <stdint.h>

#define PTYPE_TEXT 0
#define PTYPE_RESPONSE 1
#define PTYPE_MULTICAST 2
#define PTYPE_CLIENT 3
#define PTYPE_SYSTEM 4
#define PTYPE_HARBOR 5
#define PTYPE_SOCKET 6
// read lualib/skynet.lua examples/simplemonitor.lua
#define PTYPE_ERROR 7	
// read lualib/skynet.lua lualib/mqueue.lua lualib/snax.lua
#define PTYPE_RESERVED_QUEUE 8
#define PTYPE_RESERVED_DEBUG 9
#define PTYPE_RESERVED_LUA 10
#define PTYPE_RESERVED_SNAX 11

#define PTYPE_TAG_DONTCOPY 0x10000
#define PTYPE_TAG_ALLOCSESSION 0x20000

struct skynet_context;

/* context所指向的源服务，向logger服务发送一条字符串 */
void skynet_error(struct skynet_context * context, const char *msg, ...);

/* 执行某个命令，并返回执行结果 */
const char * skynet_command(struct skynet_context * context, const char * cmd , const char * parm);

/* 根据一个本地名(.xxxx)或者(:12345678)得到此服务的handle */
uint32_t skynet_queryname(struct skynet_context * context, const char * name);

/* 向某个服务发送一条消息，返回session */
int skynet_send(struct skynet_context * context, uint32_t source, uint32_t destination , int type, int session, void * msg, size_t sz);

/* 向指定名字的服务发送一条消息，可以是其它节点的服务 */
int skynet_sendname(struct skynet_context * context, uint32_t source, const char * destination , int type, int session, void * msg, size_t sz);

/* 判断handle是否是其它节点的服务句柄 */
int skynet_isremote(struct skynet_context *, uint32_t handle, int * harbor);

/* 设置消息处理的回调函数，回调函数返回0表明系统在回调完成之后接收方会free这个msg */
typedef int (*skynet_cb)(struct skynet_context * context, void *ud, int type, int session, uint32_t source , const void * msg, size_t sz);
void skynet_callback(struct skynet_context * context, void *ud, skynet_cb cb);

/* 当前线程正在处理的服务句柄 */
uint32_t skynet_current_handle(void);

/* 自从1970.01.01到现在的时间，centisecond */
uint64_t skynet_now(void);

void skynet_debug_memory(const char *info);	// for debug use, output current service memory to stderr

#endif

// type 表示的是当前消息包的协议组别
// session可以认为是一次会话(rpc)的id,通常发起方会分配一个新的session id，应答的时候使用这个老的id