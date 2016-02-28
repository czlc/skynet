#ifndef skynet_socket_h
#define skynet_socket_h

struct skynet_context;

#define SKYNET_SOCKET_TYPE_DATA 1			// [C/S]�����ݵ���
#define SKYNET_SOCKET_TYPE_CONNECT 2		// [C]�����˷����
#define SKYNET_SOCKET_TYPE_CLOSE 3
#define SKYNET_SOCKET_TYPE_ACCEPT 4			// [S]accept�˿ͻ��ˣ�����START֮ǰ���������ݽ���
#define SKYNET_SOCKET_TYPE_ERROR 5
#define SKYNET_SOCKET_TYPE_UDP 6
#define SKYNET_SOCKET_TYPE_WARNING 7

struct skynet_socket_message {
	int type;		// ����
	int id;			// socket id
	int ud;			// for accept, ud is listen id ; for data, ud is size of data 
	char * buffer;	// padding���͵�������skynet_socket_message֮�� 
};

void skynet_socket_init();	// ����socket��Դ
void skynet_socket_exit();	// �˳�socket�߳�
void skynet_socket_free();	// �ͷ�socket��Դ
int skynet_socket_poll();	// breath

int skynet_socket_send(struct skynet_context *ctx, int id, void *buffer, int sz);
void skynet_socket_send_lowpriority(struct skynet_context *ctx, int id, void *buffer, int sz);
int skynet_socket_listen(struct skynet_context *ctx, const char *host, int port, int backlog);
int skynet_socket_connect(struct skynet_context *ctx, const char *host, int port);
int skynet_socket_bind(struct skynet_context *ctx, int fd);
void skynet_socket_close(struct skynet_context *ctx, int id);
void skynet_socket_shutdown(struct skynet_context *ctx, int id);
void skynet_socket_start(struct skynet_context *ctx, int id);
void skynet_socket_nodelay(struct skynet_context *ctx, int id);

int skynet_socket_udp(struct skynet_context *ctx, const char * addr, int port);
int skynet_socket_udp_connect(struct skynet_context *ctx, int id, const char * addr, int port);
int skynet_socket_udp_send(struct skynet_context *ctx, int id, const char * address, const void *buffer, int sz);
const char * skynet_socket_udp_address(struct skynet_socket_message *, int *addrsz);

#endif
