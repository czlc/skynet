/* 处理 socket 相关，不关心服务 */
#ifndef skynet_socket_server_h
#define skynet_socket_server_h

#include <stdint.h>

#define SOCKET_DATA 0
#define SOCKET_CLOSE 1
#define SOCKET_OPEN 2
#define SOCKET_ACCEPT 3
#define SOCKET_ERR 4
#define SOCKET_EXIT 5
#define SOCKET_UDP 6
#define SOCKET_WARNING 7

struct socket_server;

// 收集到的message，用于回应发出socket请求的ctx
struct socket_message {
	int id;
	uintptr_t opaque; // ctx handle
	int ud;	// for accept, ud is new connection id ; for data, ud is size of data 
	char * data;
};

struct socket_server * socket_server_create();
void socket_server_release(struct socket_server *);
int socket_server_poll(struct socket_server *, struct socket_message *result, int *more);

void socket_server_exit(struct socket_server *);
/* 将缓冲区的东西都发送完毕才执行关闭 */
void socket_server_close(struct socket_server *, uintptr_t opaque, int id);
/* 无论缓冲区是否有东西都直接关闭 */
void socket_server_shutdown(struct socket_server *, uintptr_t opaque, int id);

/* opaque 是发起start的服务handle */
void socket_server_start(struct socket_server *, uintptr_t opaque, int id);

// return -1 when error
int socket_server_send(struct socket_server *, int id, const void * buffer, int sz);
int socket_server_send_lowpriority(struct socket_server *, int id, const void * buffer, int sz);

// ctrl command below returns id
int socket_server_listen(struct socket_server *, uintptr_t opaque, const char * addr, int port, int backlog);

/* 连接addr:port ，opaque是发起连接的service的handle*/
int socket_server_connect(struct socket_server *, uintptr_t opaque, const char * addr, int port);

/* */
int socket_server_bind(struct socket_server *, uintptr_t opaque, int fd);

// for tcp
void socket_server_nodelay(struct socket_server *, int id);

struct socket_udp_address;

// create an udp socket handle, attach opaque with it . udp socket don't need call socket_server_start to recv message
// if port != 0, bind the socket . if addr == NULL, bind ipv4 0.0.0.0 . If you want to use ipv6, addr can be "::" and port 0.
int socket_server_udp(struct socket_server *, uintptr_t opaque, const char * addr, int port);
// set default dest address, return 0 when success
int socket_server_udp_connect(struct socket_server *, int id, const char * addr, int port);
// If the socket_udp_address is NULL, use last call socket_server_udp_connect address instead
// You can also use socket_server_send 
int socket_server_udp_send(struct socket_server *, int id, const struct socket_udp_address *, const void *buffer, int sz);
// extract the address of the message, struct socket_message * should be SOCKET_UDP
const struct socket_udp_address * socket_server_udp_address(struct socket_server *, struct socket_message *, int *addrsz);

// https://groups.google.com/forum/#!topic/skynet-users/Xzgy6d4H0HQ
struct socket_object_interface {
	void * (*buffer)(void *);	// 获得buffer数据
	int (*size)(void *);		// 获得buffer大小
	void (*free)(void *);		// 释放buffer，可定制的好处是可以用个引用计数，这样广播的时候就没必要复制数据了
};

// if you send package sz == -1, use soi.
void socket_server_userobject(struct socket_server *, struct socket_object_interface *soi);

#endif
