/* hook中通过实现malloc同名api来重载libc的实现，这在macos下行不通 */
#ifndef skynet_malloc_h
#define skynet_malloc_h

#include <stddef.h>

#define skynet_malloc malloc
#define skynet_calloc calloc
#define skynet_realloc realloc
#define skynet_free free

/* 函数声明，避免警告 */
void * skynet_malloc(size_t sz);
void * skynet_calloc(size_t nmemb,size_t size);
void * skynet_realloc(void *ptr, size_t size);
void skynet_free(void *ptr);
char * skynet_strdup(const char *str);
void * skynet_lalloc(void *ptr, size_t osize, size_t nsize);	// use for lua

#endif
