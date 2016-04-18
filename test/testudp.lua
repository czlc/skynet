local skynet = require "skynet"
local socket = require "socket"

local function server()
	local host -- host 是 socket id
	host = socket.udp(function(str, from)
		print("server recv", str, socket.udp_address(from))
		socket.sendto(host, from, "OK " .. str)
	end , "127.0.0.1", 8765)	-- bind an address
end

local function client()
	-- socket.udp，没有写ip和port，表示这是一个发送socket
	local c = socket.udp(function(str, from)
		print("client recv", str, socket.udp_address(from))
	end)
	socket.udp_connect(c, "127.0.0.1", 8765)
	for i=1,20 do
		socket.write(c, "hello " .. i)	-- write to the address by udp_connect binding
	end
end

skynet.start(function()
	skynet.fork(server)
	skynet.fork(client)
end)
