-- 相当于是agent的manager
local skynet = require "skynet"
local netpack = require "netpack"

local CMD = {}
local SOCKET = {}
local gate
local agent = {}

-- gate accept了客户端连接，由watchdog创建agent，同于一对一的通信
function SOCKET.open(fd, addr)
	skynet.error("New client from : " .. addr)
	agent[fd] = skynet.newservice("agent") -- 创建一个agent用于处理客户端消息
	skynet.call(agent[fd], "lua", "start", { gate = gate, client = fd, watchdog = skynet.self() })
end

local function close_agent(fd)
	local a = agent[fd]
	agent[fd] = nil
	if a then
		skynet.call(gate, "lua", "kick", fd)
		-- disconnect never return
		skynet.send(a, "lua", "disconnect")
	end
end

function SOCKET.close(fd)
	print("socket close",fd)
	close_agent(fd)
end

function SOCKET.error(fd, msg)
	print("socket error",fd, msg)
	close_agent(fd)
end

function SOCKET.warning(fd, size)
	-- size K bytes havn't send out in fd
	print("socket warning", fd, size)
end

function SOCKET.data(fd, msg)
end

-- conf = {address, prot, maxclient}
-- 监听并等待连入的TCP连接
function CMD.start(conf)
	skynet.call(gate, "lua", "open" , conf)
end

function CMD.close(fd)
	close_agent(fd)
end

skynet.start(function()
	skynet.dispatch("lua", function(session, source, cmd, subcmd, ...)
		if cmd == "socket" then -- 来自gate服务
			local f = SOCKET[subcmd]
			f(...)
			-- socket api don't need return
		else
			local f = assert(CMD[cmd])
			skynet.ret(skynet.pack(f(subcmd, ...)))
		end
	end)

	gate = skynet.newservice("gate")	-- 启动一个gate服务用于接受连入的TCP连接 
end)
