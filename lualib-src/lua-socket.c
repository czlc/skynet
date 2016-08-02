/* ��lua-netpack��ͬ������û�зְ������ǵ���һ����������۴�С���ȴ�������ȡ��ʱ����Ҫָ����С���߸��ݷָ��� */
#include "skynet_malloc.h"

#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <assert.h>

#include <lua.h>
#include <lauxlib.h>

#include <sys/socket.h>
#include <arpa/inet.h>

#include "skynet_socket.h"

#define BACKLOG 32
// 2 ** 12 == 4096
#define LARGE_PAGE_NODE 12
#define BUFFER_LIMIT (256 * 1024)

// һ��node��ʾһ�����ݰ�
struct buffer_node {
	char * msg;		// ���ݰ�����
	int sz;			// ���ݰ����ݳ���
	struct buffer_node *next;	// ��һ�����ݰ�
};

// ����һ��socket�ϵ����ݰ��б�
struct socket_buffer {
	int size;					// ��socket���ܵ���δ�����ݴ�С
	int offset;					// ��ǰbuffer_node���Ѷ�ƫ��
	struct buffer_node *head;	// ���ݰ��б��ͷ
	struct buffer_node *tail;	// ���ݰ��б��β
};

static int
lfreepool(lua_State *L) {
	struct buffer_node * pool = lua_touserdata(L, 1);
	int sz = lua_rawlen(L,1) / sizeof(*pool);
	int i;
	for (i=0;i<sz;i++) {
		struct buffer_node *node = &pool[i];
		if (node->msg) {
			skynet_free(node->msg);
			node->msg = NULL;
		}
	}
	return 0;
}

/* �����ڴ��(buffers chunk)��ӵ��sz��buffer_node */
static int
lnewpool(lua_State *L, int sz) {
	struct buffer_node * pool = lua_newuserdata(L, sizeof(struct buffer_node) * sz);
	int i;
	for (i=0;i<sz;i++) {
		pool[i].msg = NULL;
		pool[i].sz = 0;
		pool[i].next = &pool[i+1];
	}
	pool[sz-1].next = NULL;
	if (luaL_newmetatable(L, "buffer_pool")) {
		lua_pushcfunction(L, lfreepool);
		lua_setfield(L, -2, "__gc");
	}
	lua_setmetatable(L, -2);	// -2Ϊnew userdata
	return 1;
}

/* ����һ��socket �շ����� */
static int
lnewbuffer(lua_State *L) {
	struct socket_buffer * sb = lua_newuserdata(L, sizeof(*sb));	
	sb->size = 0;
	sb->offset = 0;
	sb->head = NULL;
	sb->tail = NULL;
	
	return 1;
}

/*
	�ű��յ����ݰ����������������������յ�ȴΪ����ȡ���ܵĴ�С
	userdata send_buffer
	table pool
	lightuserdata msg
	int size

	return size(��socket���ܵ�δ���ֽڴ�С)

	Comment: The table pool record all the buffers chunk, 
	and the first index [1] is a lightuserdata : free_node. We can always use this pointer for struct buffer_node .
	The following ([2] ...)  userdatas in table pool is the buffer chunk (for struct buffer_node), 
	we never free them until the VM closed(��Ϊ��userdata�������Զ��ͷţ��������µ�msg��Ҫ��һ�ͷ�:��lnewpool). The size of first
	chunk ([2]) is 16 struct buffer_node,and the second size is 32 ... The largest size of chunk is LARGE_PAGE_NODE (4096)

	lpushbbuffer will get a free struct buffer_node from table pool, and then put the msg/size in it.
	lpopbuffer return the struct buffer_node back to table pool (By calling return_free_node).
 */
static int
lpushbuffer(lua_State *L) {
	struct socket_buffer *sb = lua_touserdata(L,1);
	if (sb == NULL) {
		return luaL_error(L, "need buffer object at param 1");
	}
	char * msg = lua_touserdata(L,3);
	if (msg == NULL) {
		return luaL_error(L, "need message block at param 3");
	}
	int pool_index = 2;
	luaL_checktype(L,pool_index,LUA_TTABLE);
	int sz = luaL_checkinteger(L,4);
	lua_rawgeti(L,pool_index,1);	// ���buffer_pool�ĵ�һ��Ԫ��
	struct buffer_node * free_node = lua_touserdata(L,-1);	// sb poolt msg size free_node
	lua_pop(L,1);
	if (free_node == NULL) {
		int tsz = lua_rawlen(L,pool_index);	// �鿴buffer_pool�ĳ���
		if (tsz == 0)
			tsz++;
		// size ��buffer_node����
		int size = 8;
		if (tsz <= LARGE_PAGE_NODE-3) {
			// ǰ��8��size�𽥵���:16,32,....1024
			size <<= tsz;
		} else {
			// 8��֮��Ķ��ǹ̶�4096һ��
			size <<= LARGE_PAGE_NODE-3;
		}
		lnewpool(L, size);	// ����һ��buffer_node ������
		free_node = lua_touserdata(L,-1);
		lua_rawseti(L, pool_index, tsz+1);	// ռλ��,���������𼶷��䲻ͬ��Ŀ��buffer_node
	}
	// free_node �����ã���������һ��ѹ��
	lua_pushlightuserdata(L, free_node->next);	
	lua_rawseti(L, pool_index, 1);	// sb poolt msg size
	free_node->msg = msg;
	free_node->sz = sz;
	free_node->next = NULL;

	// ����socket_buffer �б�
	if (sb->head == NULL) {
		assert(sb->tail == NULL);
		sb->head = sb->tail = free_node;
	} else {
		sb->tail->next = free_node;
		sb->tail = free_node;
	}
	sb->size += sz;

	lua_pushinteger(L, sb->size);

	return 1;
}

// �����ˣ������ͷ��˴˽ڵ㵽free_node�б���ȥ
static void
return_free_node(lua_State *L, int pool, struct socket_buffer *sb) {
	struct buffer_node *free_node = sb->head;
	sb->offset = 0;
	sb->head = free_node->next;
	if (sb->head == NULL) {
		sb->tail = NULL;
	}
	// free_node �ͷ���պ���뵽buffer_pool[1]
	lua_rawgeti(L,pool,1);
	free_node->next = lua_touserdata(L,-1);
	lua_pop(L,1);
	skynet_free(free_node->msg);
	free_node->msg = NULL;

	free_node->sz = 0;
	lua_pushlightuserdata(L, free_node);
	lua_rawseti(L, pool, 1);
}

// skip ��ʾsz��С���ж����Ǳ����Եģ����üӵ������еģ�����
// ���õ�����˵��sb�������㹻������(>= sz)
// ���Կ�Խ������ݰ�
static void
pop_lstring(lua_State *L, struct socket_buffer *sb, int sz, int skip) {
	struct buffer_node * current = sb->head;
	if (sz < current->sz - sb->offset) {
		lua_pushlstring(L, current->msg + sb->offset, sz-skip);
		sb->offset+=sz;
		return;
	}
	if (sz == current->sz - sb->offset) {
		lua_pushlstring(L, current->msg + sb->offset, sz-skip);
		return_free_node(L,2,sb);
		return;
	}

	luaL_Buffer b;
	luaL_buffinit(L, &b);
	for (;;) {
		// �ȴӴ�node��ʣ�����ݶ�
		int bytes = current->sz - sb->offset;	// ��node��ʣ��δ������
		if (bytes >= sz) {
			if (sz > skip) {
				luaL_addlstring(&b, current->msg + sb->offset, sz - skip);
			} 
			sb->offset += sz;
			if (bytes == sz) {
				return_free_node(L,2,sb);
			}
			break;
		}
		int real_sz = sz - skip;
		if (real_sz > 0) {	// ��ǰ�ڵ��ȫ����
			luaL_addlstring(&b, current->msg + sb->offset, (real_sz < bytes) ? real_sz : bytes);
		}
		return_free_node(L,2,sb);
		sz-=bytes;	// ����Ҫ��sz
		if (sz==0)
			break;
		current = sb->head;	// ����һ���ڵ�
		assert(current);
	}
	luaL_pushresult(&b);
}

static int
lheader(lua_State *L) {
	size_t len;
	const uint8_t * s = (const uint8_t *)luaL_checklstring(L, 1, &len);
	if (len > 4 || len < 1) {
		return luaL_error(L, "Invalid read %s", s);
	}
	int i;
	size_t sz = 0;
	for (i=0;i<(int)len;i++) {
		sz <<= 8;
		sz |= s[i];
	}

	lua_pushinteger(L, (lua_Integer)sz);

	return 1;
}

/*
	userdata send_buffer
	table pool
	integer sz 
	��socket �϶�ȡsz���ֽ�
 */
static int
lpopbuffer(lua_State *L) {
	struct socket_buffer * sb = lua_touserdata(L, 1);
	if (sb == NULL) {
		return luaL_error(L, "Need buffer object at param 1");
	}
	luaL_checktype(L,2,LUA_TTABLE);
	int sz = luaL_checkinteger(L,3);
	// ��ǰsocket��û���յ���ô������
	if (sb->size < sz || sz == 0) {
		lua_pushnil(L);
	} else {
		pop_lstring(L,sb,sz,0);
		sb->size -= sz;
	}
	lua_pushinteger(L, sb->size);

	return 2;
}

/*
	userdata send_buffer
	table pool
	���һ��socket�յ������ݰ�
 */
static int
lclearbuffer(lua_State *L) {
	struct socket_buffer * sb = lua_touserdata(L, 1);
	if (sb == NULL) {
		return luaL_error(L, "Need buffer object at param 1");
	}
	luaL_checktype(L,2,LUA_TTABLE);
	while(sb->head) {
		return_free_node(L,2,sb);
	}
	sb->size = 0;
	return 0;
}

/* ����ָ��socket�յ����������� */
static int
lreadall(lua_State *L) {
	struct socket_buffer * sb = lua_touserdata(L, 1);
	if (sb == NULL) {
		return luaL_error(L, "Need buffer object at param 1");
	}
	luaL_checktype(L,2,LUA_TTABLE);
	luaL_Buffer b;
	luaL_buffinit(L, &b);
	while(sb->head) {
		struct buffer_node *current = sb->head;
		luaL_addlstring(&b, current->msg + sb->offset, current->sz - sb->offset);
		return_free_node(L,2,sb);
	}
	luaL_pushresult(&b);
	sb->size = 0;	// ȫ��������
	return 1;
}

static int
ldrop(lua_State *L) {
	void * msg = lua_touserdata(L,1);
	luaL_checkinteger(L,2);
	skynet_free(msg);
	return 0;
}

/* �����ݰ�node��frome�ֽڴ���ʼ���� ���Ƿ��Ƿָ��ַ��� sep*/
static bool
check_sep(struct buffer_node * node, int from, const char *sep, int seplen) {
	for (;;) {
		int sz = node->sz - from;	// �����ݰ���ʣ�����ֽڿ��Զ�
		if (sz >= seplen) {
			return memcmp(node->msg+from,sep,seplen) == 0;
		}
		if (sz > 0) {
			// �Ƿ񲿷���ͬ�������ͬ��������һ���ڵ�
			if (memcmp(node->msg + from, sep, sz)) {
				return false;
			}
		}
		node = node->next;
		sep += sz;
		seplen -= sz;
		from = 0;
	}
}

/*
	userdata send_buffer
	table pool , nil for check
	string sep

	����յ������ݰ����Ƿ�����ָ�������������򷵻��ַ������߽����Ǽ��ͷ��ؼ����
 */
static int
lreadline(lua_State *L) {
	struct socket_buffer * sb = lua_touserdata(L, 1);
	if (sb == NULL) {
		return luaL_error(L, "Need buffer object at param 1");
	}
	// only check
	bool check = !lua_istable(L, 2);
	size_t seplen = 0;
	const char *sep = luaL_checklstring(L,3,&seplen);	// �ָ���
	int i;
	struct buffer_node *current = sb->head;
	if (current == NULL)
		return 0;
	int from = sb->offset;				// �����ݰ�current��frome��ʼ��
	int bytes = current->sz - from;		// ���ݰ�current��ʣ������ֽڿ��Զ�
	for (i=0;i<=sb->size - (int)seplen;i++) {
		// ����sb�����пɶ����ֽڣ����Ƿ������ָ��ַ���
		if (check_sep(current, from, sep, seplen)) {
			if (check) {
				lua_pushboolean(L,true);	// ��ʾ������һ���ָ��ַ���
			} else {
				pop_lstring(L, sb, i+seplen, seplen);	// ѹ��Ŀ���ַ���
				sb->size -= i+seplen;
			}
			return 1;
		}
		++from;
		--bytes;
		if (bytes == 0) {
			// �����ݰ������ˣ������һ�����ݰ�
			current = current->next;
			from = 0;
			if (current == NULL)
				break;
			bytes = current->sz;
		}
	}
	return 0;
}

static int
lstr2p(lua_State *L) {
	size_t sz = 0;
	const char * str = luaL_checklstring(L,1,&sz);
	void *ptr = skynet_malloc(sz);
	memcpy(ptr, str, sz);
	lua_pushlightuserdata(L, ptr);
	lua_pushinteger(L, (int)sz);
	return 2;
}

// for skynet socket

/*
	lightuserdata msg
	integer size

	return type n1 n2 ptr_or_string
	���skynet_socket.c��������PTYPE_SOCKET��Ϣ����skynet_socket.c : forward_message
*/
static int
lunpack(lua_State *L) {
	struct skynet_socket_message *message = lua_touserdata(L,1);
	int size = luaL_checkinteger(L,2);

	lua_pushinteger(L, message->type);
	lua_pushinteger(L, message->id);	// socket id
	lua_pushinteger(L, message->ud);	// for accept, ud is new connection id ; for data, ud is size of data 
	if (message->buffer == NULL) {		// ��forward_message�е�padding����ʾ���ַ���
		lua_pushlstring(L, (char *)(message+1),size - sizeof(*message));
	} else {
		lua_pushlightuserdata(L, message->buffer);
	}
	if (message->type == SKYNET_SOCKET_TYPE_UDP) {
		int addrsz = 0;
		const char * addrstring = skynet_socket_udp_address(message, &addrsz);
		if (addrstring) {
			lua_pushlstring(L, addrstring, addrsz);
			return 5;
		}
	}
	return 4;
}

/*���addrΪ��ַ�Ͷ˿ڣ�����host*/
static const char *
address_port(lua_State *L, char *tmp, const char * addr, int port_index, int *port) {
	const char * host;
	if (lua_isnoneornil(L,port_index)) {
		host = strchr(addr, '[');
		if (host) {
			// is ipv6
			++host;
			const char * sep = strchr(addr,']');
			if (sep == NULL) {
				luaL_error(L, "Invalid address %s.",addr);
			}
			memcpy(tmp, host, sep-host);
			tmp[sep-host] = '\0';
			host = tmp;
			sep = strchr(sep + 1, ':');
			if (sep == NULL) {
				luaL_error(L, "Invalid address %s.",addr);
			}
			*port = strtoul(sep+1,NULL,10);
		} else {
			// is ipv4
			const char * sep = strchr(addr,':');
			if (sep == NULL) {
				luaL_error(L, "Invalid address %s.",addr);
			}
			memcpy(tmp, addr, sep-addr);
			tmp[sep-addr] = '\0';
			host = tmp;
			*port = strtoul(sep+1,NULL,10);
		}
	} else {
		host = addr;
		*port = luaL_optinteger(L,port_index, 0);
	}
	return host;
}

static int
lconnect(lua_State *L) {
	size_t sz = 0;
	const char * addr = luaL_checklstring(L,1,&sz);
	char tmp[sz];
	int port = 0;
	const char * host = address_port(L, tmp, addr, 2, &port);
	if (port == 0) {
		return luaL_error(L, "Invalid port");
	}
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	int id = skynet_socket_connect(ctx, host, port);
	lua_pushinteger(L, id);

	return 1;
}

static int
lclose(lua_State *L) {
	int id = luaL_checkinteger(L,1);
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	skynet_socket_close(ctx, id);
	return 0;
}

static int
lshutdown(lua_State *L) {
	int id = luaL_checkinteger(L,1);
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	skynet_socket_shutdown(ctx, id);
	return 0;
}

static int
llisten(lua_State *L) {
	const char * host = luaL_checkstring(L,1);
	int port = luaL_checkinteger(L,2);
	int backlog = luaL_optinteger(L,3,BACKLOG);
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	int id = skynet_socket_listen(ctx, host,port,backlog);
	if (id < 0) {
		return luaL_error(L, "Listen error");
	}

	lua_pushinteger(L,id);
	return 1;
}

static size_t
count_size(lua_State *L, int index) {
	size_t tlen = 0;
	int i;
	for (i=1;lua_geti(L, index, i) != LUA_TNIL; ++i) {
		size_t len;
		luaL_checklstring(L, -1, &len);
		tlen += len;
		lua_pop(L,1);
	}
	lua_pop(L,1);
	return tlen;
}

/* ��һ��string table���л���һ���ַ��� */
static void
concat_table(lua_State *L, int index, void *buffer, size_t tlen) {
	char *ptr = buffer;
	int i;
	for (i=1;lua_geti(L, index, i) != LUA_TNIL; ++i) {
		size_t len;
		const char * str = lua_tolstring(L, -1, &len);
		if (str == NULL || tlen < len) {
			break;
		}
		memcpy(ptr, str, len);
		ptr += len;
		tlen -= len;
		lua_pop(L,1);
	}
	if (tlen != 0) {
		skynet_free(buffer);
		luaL_error(L, "Invalid strings table");
	}
	lua_pop(L,1);
}

/* ��index����luaԪ��ת��Ϊһ���ַ����� sz�Ƿ����ַ����ĳ��� */
static void *
get_buffer(lua_State *L, int index, int *sz) {
	void *buffer;
	switch(lua_type(L, index)) {
		const char * str;
		size_t len;
	case LUA_TUSERDATA:
	case LUA_TLIGHTUSERDATA:
		// �������2�����ͣ�����Ҫ����һ��size
		buffer = lua_touserdata(L,index);
		*sz = luaL_checkinteger(L,index+1);
		break;
	case LUA_TTABLE:
		// concat the table as a string
		// �˱�涨��ֻ����Ĭ������������ÿһ����ַ���
		len = count_size(L, index);
		buffer = skynet_malloc(len);
		concat_table(L, index, buffer, len);
		*sz = (int)len;
		break;
	default:
		str =  luaL_checklstring(L, index, &len);
		buffer = skynet_malloc(len);
		memcpy(buffer, str, len);
		*sz = (int)len;
		break;
	}
	return buffer;
}

static int
lsend(lua_State *L) {
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	int id = luaL_checkinteger(L, 1);	// socket id
	int sz = 0;
	void *buffer = get_buffer(L, 2, &sz);
	int err = skynet_socket_send(ctx, id, buffer, sz);
	lua_pushboolean(L, !err);
	return 1;
}

static int
lsendlow(lua_State *L) {
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	int id = luaL_checkinteger(L, 1);
	int sz = 0;
	void *buffer = get_buffer(L, 2, &sz);
	skynet_socket_send_lowpriority(ctx, id, buffer, sz);
	return 0;
}

static int
lbind(lua_State *L) {
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	int fd = luaL_checkinteger(L, 1);
	int id = skynet_socket_bind(ctx,fd);
	lua_pushinteger(L,id);
	return 1;
}

static int
lstart(lua_State *L) {
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	int id = luaL_checkinteger(L, 1);
	skynet_socket_start(ctx,id);
	return 0;
}

static int
lnodelay(lua_State *L) {
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	int id = luaL_checkinteger(L, 1);
	skynet_socket_nodelay(ctx,id);
	return 0;
}

/* ����һ��udp socket id������addr��port */
static int
ludp(lua_State *L) {
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	size_t sz = 0;
	const char * addr = lua_tolstring(L,1,&sz);
	char tmp[sz];
	int port = 0;
	const char * host = NULL;
	if (addr) {
		host = address_port(L, tmp, addr, 2, &port);
	}

	int id = skynet_socket_udp(ctx, host, port);
	if (id < 0) {
		return luaL_error(L, "udp init failed");
	}
	lua_pushinteger(L, id);
	return 1;
}

static int
ludp_connect(lua_State *L) {
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	int id = luaL_checkinteger(L, 1);
	size_t sz = 0;
	const char * addr = luaL_checklstring(L,2,&sz);
	char tmp[sz];
	int port = 0;
	const char * host = NULL;
	if (addr) {
		host = address_port(L, tmp, addr, 3, &port);
	}

	if (skynet_socket_udp_connect(ctx, id, host, port)) {
		return luaL_error(L, "udp connect failed");
	}

	return 0;
}

static int
ludp_send(lua_State *L) {
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	int id = luaL_checkinteger(L, 1);
	const char * address = luaL_checkstring(L, 2);	// udp ��ַ
	int sz = 0;
	void *buffer = get_buffer(L, 3, &sz);
	int err = skynet_socket_udp_send(ctx, id, address, buffer, sz);

	lua_pushboolean(L, !err);

	return 1;
}

/* ��udp��ַ����Ϊ�ɶ���addr��port */
static int
ludp_address(lua_State *L) {
	size_t sz = 0;
	const uint8_t * addr = (const uint8_t *)luaL_checklstring(L, 1, &sz);
	uint16_t port = 0;
	memcpy(&port, addr+1, sizeof(uint16_t));
	port = ntohs(port);	/* converts the unsigned integer arg from network byte order to host byte order. */
	const void * src = addr+3;
	char tmp[256];
	int family;
	if (sz == 1+2+4) {
		// 1 type, 2 port, 4 ipv4
		family = AF_INET;
	} else {
		// 1 type, 2 port, 16 ipv6
		if (sz != 1+2+16) {
			return luaL_error(L, "Invalid udp address");
		}
		family = AF_INET6;
	}
	// inet_ntop converts the network address structure src in the af address family into a character string.
	if (inet_ntop(family, src, tmp, sizeof(tmp)) == NULL) {
		return luaL_error(L, "Invalid udp address");
	}
	lua_pushstring(L, tmp);
	lua_pushinteger(L, port);
	return 2;
}

int
luaopen_socketdriver(lua_State *L) {
	luaL_checkversion(L);
	luaL_Reg l[] = {
		{ "buffer", lnewbuffer },
		{ "push", lpushbuffer },
		{ "pop", lpopbuffer },
		{ "drop", ldrop },
		{ "readall", lreadall },
		{ "clear", lclearbuffer },
		{ "readline", lreadline },
		{ "str2p", lstr2p },
		{ "header", lheader },

		{ "unpack", lunpack },
		{ NULL, NULL },
	};
	luaL_newlib(L,l);
	// ������Щ����ע���upvalue:ctx
	luaL_Reg l2[] = {
		{ "connect", lconnect },
		{ "close", lclose },
		{ "shutdown", lshutdown },
		{ "listen", llisten },
		{ "send", lsend },
		{ "lsend", lsendlow },
		{ "bind", lbind },
		{ "start", lstart },
		{ "nodelay", lnodelay },
		{ "udp", ludp },
		{ "udp_connect", ludp_connect },
		{ "udp_send", ludp_send },
		{ "udp_address", ludp_address },
		{ NULL, NULL },
	};
	lua_getfield(L, LUA_REGISTRYINDEX, "skynet_context");
	struct skynet_context *ctx = lua_touserdata(L,-1);
	if (ctx == NULL) {
		return luaL_error(L, "Init skynet context first");
	}

	luaL_setfuncs(L,l2,1);

	return 1;
}
