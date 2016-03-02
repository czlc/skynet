-- https://github.com/cloudwu/skynet/wiki/GateServer
-- gateserver是个框架(也可以理解为service的基类，具体的处理函数由start传入的参数处理)，gate|msgserver是在其上的实现
local skynet = require "skynet"
local netpack = require "netpack"
local socketdriver = require "socketdriver"

local gateserver = {}

local socket	-- listen socket
local queue		-- message queue
local maxclient	-- max client
local client_number = 0
local CMD = setmetatable({}, { __gc = function() netpack.clear(queue) end })
local nodelay = false

local connection = {}

function gateserver.openclient(fd)
	if connection[fd] then
		socketdriver.start(fd)
	end
end

function gateserver.closeclient(fd)
	local c = connection[fd]
	if c then
		connection[fd] = false
		socketdriver.close(fd)
	end
end

-- 启动一个网关服务, handler 是一组自定义的消息处理函数(msgserver.lua | gate.lua)
function gateserver.start(handler)
	assert(handler.message)
	assert(handler.connect)

	-- source 表明是谁启动了这个gate服务
	-- 见main.lua, conf = {	port = 8888,maxclient = 64,	servername = "sample",}
	function CMD.open( source, conf )
		assert(not socket)
		local address = conf.address or "0.0.0.0"
		local port = assert(conf.port)
		maxclient = conf.maxclient or 1024
		nodelay = conf.nodelay
		skynet.error(string.format("Listen on %s:%d", address, port))
		socket = socketdriver.listen(address, port)
		socketdriver.start(socket)
		if handler.open then
			return handler.open(source, conf)
		end
	end

	function CMD.close()
		assert(socket)
		socketdriver.close(socket)
	end

	local MSG = {}

	local function dispatch_msg(fd, msg, sz)
		if connection[fd] then
			handler.message(fd, msg, sz)
		else
			skynet.error(string.format("Drop message from fd (%d) : %s", fd, netpack.tostring(msg,sz)))
		end
	end

	MSG.data = dispatch_msg

	local function dispatch_queue()
		local fd, msg, sz = netpack.pop(queue)
		if fd then
			-- may dispatch even the handler.message blocked
			-- If the handler.message never block, the queue should be empty, so only fork once and then exit.
			skynet.fork(dispatch_queue)	-- 可以并行处理多个msg，它们的先后关系不要紧
			dispatch_msg(fd, msg, sz)

			for fd, msg, sz in netpack.pop, queue do
				dispatch_msg(fd, msg, sz)
			end
		end
	end

	MSG.more = dispatch_queue

	function MSG.open(fd, msg)
		if client_number >= maxclient then
			socketdriver.close(fd)
			return
		end
		if nodelay then
			socketdriver.nodelay(fd)
		end
		connection[fd] = true
		client_number = client_number + 1
		handler.connect(fd, msg)
	end

	local function close_fd(fd)
		local c = connection[fd]
		if c ~= nil then
			connection[fd] = nil
			client_number = client_number - 1
		end
	end

	function MSG.close(fd)
		if fd ~= socket then
			if handler.disconnect then
				handler.disconnect(fd)
			end
			close_fd(fd)
		else
			socket = nil
		end
	end

	function MSG.error(fd, msg)
		if fd == socket then
			socketdriver.close(fd)
			skynet.error(msg)
		else
			if handler.error then
				handler.error(fd, msg)
			end
			close_fd(fd)
		end
	end

	function MSG.warning(fd, size)
		if handler.warning then
			handler.warning(fd, size)
		end
	end

	skynet.register_protocol {
		name = "socket",
		id = skynet.PTYPE_SOCKET,	-- PTYPE_SOCKET = 6
		unpack = function ( msg, sz )
			return netpack.filter( queue, msg, sz)
		end,
		-- dispatch 的参数是session, source, unpack(msg, sz, ...)
		dispatch = function (_, _, q, type, ...)
			queue = q
			if type then
				MSG[type](...)
			end
		end
	}

	skynet.start(function()
		skynet.dispatch("lua", function (_, address, cmd, ...)
			local f = CMD[cmd]
			if f then
				skynet.ret(skynet.pack(f(address, ...)))
			else
				skynet.ret(skynet.pack(handler.command(cmd, address, ...)))
			end
		end)
	end)
end

return gateserver
