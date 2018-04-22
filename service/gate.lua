-- gate ��λ�ڸ�Ч����������ⲿ tcp ������
-- http://blog.codingnow.com/2014/04/skynet_gate_lua_version.html
-- gateserver������Ҫ�����������Ӻ���Ϣ��������socket�㣬��gate�������ϵķ�װ���ṩ�˹����ʹ�õĽӿ�
-- ��Ϣת��
local skynet = require "skynet"
local gateserver = require "snax.gateserver"
local netpack = require "skynet.netpack"

local watchdog
local connection = {}	-- fd -> connection : { fd , client, agent , ip, mode }����Ҫ������agentת����Ϣ��������ͨ��watchdog
local forwarding = {}	-- agent -> connection��ò����ʱû��

skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
}

local handler = {}

-- �����ϣ���ڼ����˿ڴ򿪵�ʱ����һЩ��ʼ�������������ṩ open ���������source ��������Դ��ַ��conf �ǿ��� gate ����Ĳ�����
-- conf = {address, prot, maxclient}
function handler.open(source, conf)
	watchdog = conf.watchdog or source	-- watchdog ��������뿪����socket�ķ���֮���յ���Ϣ��ת����ȥ
end

function handler.message(fd, msg, sz)
	-- recv a package, forward it
	local c = connection[fd]
	local agent = c.agent
	if agent then
		skynet.redirect(agent, c.client, "client", fd, msg, sz)
	else
		skynet.send(watchdog, "lua", "socket", "data", fd, netpack.tostring(msg, sz))
	end
end

-- ��һ�������ӽ�����connect ���������á��������ӵ� socket fd ��
-- �����ӵ� ip ��ַ��ͨ������ log �������
-- ��ʱ������ͨ�ţ���Ҫstart֮��
function handler.connect(fd, addr)
	local c = {
		fd = fd,
		ip = addr,
	}
	connection[fd] = c
	skynet.send(watchdog, "lua", "socket", "open", fd, addr)
end

local function unforward(c)
	if c.agent then
		forwarding[c.agent] = nil
		c.agent = nil
		c.client = nil
	end
end

local function close_fd(fd)
	local c = connection[fd]
	if c then
		unforward(c)
		connection[fd] = nil
	end
end

-- ��һ�����ӶϿ���disconnect �����ã�fd ��ʾ���ĸ����ӡ�
function handler.disconnect(fd)
	close_fd(fd)
	skynet.send(watchdog, "lua", "socket", "close", fd)
end

-- ��һ�������쳣��ͨ����ζ�ŶϿ�����error �����ã����� fd ������
-- �õ�������Ϣ msg��ͨ������ log �������
function handler.error(fd, msg)
	close_fd(fd)
	skynet.send(watchdog, "lua", "socket", "error", fd, msg)
end

function handler.warning(fd, size)
	skynet.send(watchdog, "lua", "socket", "warning", fd, size)
end

local CMD = {}

function CMD.forward(source, fd, client, address)
	local c = assert(connection[fd])
	unforward(c)
	c.client = client or 0
	c.agent = address or source
	forwarding[c.agent] = c
	gateserver.openclient(fd)
end

function CMD.accept(source, fd)
	local c = assert(connection[fd])
	unforward(c)
	gateserver.openclient(fd)
end

function CMD.kick(source, fd)
	gateserver.closeclient(fd)
end

-- �����ϣ���÷�����һЩ skynet �ڲ���Ϣ������ע�� command ������
-- �յ� lua Э��� skynet ��Ϣ����������������cmd ����Ϣ�ĵ�һ��
-- ֵ��ͨ��Լ��Ϊһ���ַ�����ָ����ʲôָ�source ����Ϣ����Դ��ַ��
-- ��������ķ���ֵ����ͨ�� skynet.ret/skynet.pack ���ظ���Դ����
function handler.command(cmd, source, ...)
	local f = assert(CMD[cmd])
	return f(source, ...)
end

gateserver.start(handler)
