#ifndef SKYNET_CONTEXT_HANDLE_H
#define SKYNET_CONTEXT_HANDLE_H

#include <stdint.h>

// reserve high 8 bits for remote id
#define HANDLE_MASK 0xffffff
#define HANDLE_REMOTE_SHIFT 24

struct skynet_context;

/* ע��һ��ctx������������ */
uint32_t skynet_handle_register(struct skynet_context *);
int skynet_handle_retire(uint32_t handle);

/* ���� handle ���һ�� ctx�������������ü��������Ի�õĶ��󲻻ᱻ�����߳��ͷ�
** ����Ҫ�������е����ݻ��ü���
*/
struct skynet_context * skynet_handle_grab(uint32_t handle);

/* �ر����з��� */
void skynet_handle_retireall();

uint32_t skynet_handle_findname(const char * name);
const char * skynet_handle_namehandle(uint32_t handle, const char *name);

void skynet_handle_init(int harbor);

#endif
