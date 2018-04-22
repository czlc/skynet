-- gate 定位于高效管理大量的外部 tcp 长连接
-- http://blog.codingnow.com/2014/04/skynet_gate_lua_version.html
-- gateserver部分主要处理网络连接和消息，屏蔽了socket层，而gate是在其上的封装，提供了供外界使用的接口
-- 消息转发
local skynet = require "skynet"
local gateserver = require "snax.gateserver"
local netpack = require "skynet.netpack"

local watchdog
local connection = {}	-- fd -> connection : { fd , client, agent , ip, mode }，主要用于向agent转发消息，而无需通过watchdog
local forwarding = {}	-- agent -> connection，貌似暂时没用

skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
}

local handler = {}

-- 如果你希望在监听端口打开的时候，做一些初始化操作，可以提供 open 这个方法。source 是请求来源地址，conf 是开启 gate 服务的参数表。
-- conf = {address, prot, maxclient}
function handler.open(source, conf)
	watchdog = conf.watchdog or source	-- watchdog 是外界申请开启此socket的服务，之后收到消息会转发过去
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

-- 当一个新连接建立后，connect 方法被调用。传入连接的 socket fd 和
-- 新连接的 ip 地址（通常用于 log 输出）。
-- 此时还不能通信，需要start之后
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

-- 当一个连接断开，disconnect 被调用，fd 表示是哪个连接。
function handler.disconnect(fd)
	close_fd(fd)
	skynet.send(watchdog, "lua", "socket", "close", fd)
end

-- 当一个连接异常（通常意味着断开），error 被调用，除了 fd ，还会
-- 拿到错误信息 msg（通常用于 log 输出）。
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

-- 如果你希望让服务处理一些 skynet 内部消息，可以注册 command 方法。
-- 收到 lua 协议的 skynet 消息，会调用这个方法。cmd 是消息的第一个
-- 值，通常约定为一个字符串，指名是什么指令。source 是消息的来源地址。
-- 这个方法的返回值，会通过 skynet.ret/skynet.pack 返回给来源服务。
function handler.command(cmd, source, ...)
	local f = assert(CMD[cmd])
	return f(source, ...)
end

gateserver.start(handler)
