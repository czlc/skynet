/* 线程安全的分配器，通过它可以查看内存分配的统计数据 */
#ifndef SKYNET_MALLOC_HOOK_H
#define SKYNET_MALLOC_HOOK_H

#include <stdlib.h>
#include <lua.h>

/* 获得总的内存分配量 */
extern size_t malloc_used_memory(void);
/* 获得总的内存块数 */
extern size_t malloc_memory_block(void);
/* 获得内存分配信息 */
extern void   memory_info_dump(void);
extern size_t mallctl_int64(const char* name, size_t* newval);
extern int    mallctl_opt(const char* name, int* newval);
extern void   dump_c_mem(void);
extern int    dump_mem_lua(lua_State *L);
extern size_t malloc_current_memory(void);

#endif /* SKYNET_MALLOC_HOOK_H */

