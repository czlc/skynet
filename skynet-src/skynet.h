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

/* context��ָ���Դ������logger������һ���ַ��� */
void skynet_error(struct skynet_context * context, const char *msg, ...);

/* ִ��ĳ�����������ִ�н�� */
const char * skynet_command(struct skynet_context * context, const char * cmd , const char * parm);

/* ����һ��������(.xxxx)����(:12345678)�õ��˷����handle */
uint32_t skynet_queryname(struct skynet_context * context, const char * name);

/* ��ĳ��������һ����Ϣ������session */
int skynet_send(struct skynet_context * context, uint32_t source, uint32_t destination , int type, int session, void * msg, size_t sz);

/* ��ָ�����ֵķ�����һ����Ϣ�������������ڵ�ķ��� */
int skynet_sendname(struct skynet_context * context, uint32_t source, const char * destination , int type, int session, void * msg, size_t sz);

/* �ж�handle�Ƿ��������ڵ�ķ����� */
int skynet_isremote(struct skynet_context *, uint32_t handle, int * harbor);

/* ������Ϣ����Ļص��������ص���������0����ϵͳ�ڻص����֮����շ���free���msg */
typedef int (*skynet_cb)(struct skynet_context * context, void *ud, int type, int session, uint32_t source , const void * msg, size_t sz);
void skynet_callback(struct skynet_context * context, void *ud, skynet_cb cb);

/* ��ǰ�߳����ڴ���ķ����� */
uint32_t skynet_current_handle(void);

/* �Դ�1970.01.01�����ڵ�ʱ�䣬centisecond */
uint64_t skynet_now(void);

void skynet_debug_memory(const char *info);	// for debug use, output current service memory to stderr

#endif

// type ��ʾ���ǵ�ǰ��Ϣ����Э�����
// session������Ϊ��һ�λỰ(rpc)��id,ͨ�����𷽻����һ���µ�session id��Ӧ���ʱ��ʹ������ϵ�id