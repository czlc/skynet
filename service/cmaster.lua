-- 组网工作由cmaster和cslave完成
local skynet = require "skynet"
local socket = require "socket"

--[[
	master manage data :
		1. all the slaves address : id -> ipaddr:port
		2. all the global names : name -> address

	master hold connections from slaves .

	protocol slave->master :
		package size 1 byte
		type 1 byte :
			'H' : HANDSHAKE, report slave id, and address.
			'R' : REGISTER name address
			'Q' : QUERY name


	protocol master->slave:
		package size 1 byte
		type 1 byte :
			'W' : WAIT n
			'C' : CONNECT slave_id slave_address
			'N' : NAME globalname address
			'D' : DISCONNECT slave_id
]]

local slave_node = {}  -- 连接上来的slave [slave_id] -> {fd, id, addr}
local global_name = {}	-- slave的全局名字 [globalname] -> serivce addr

local function read_package(fd)
	local sz = socket.read(fd, 1)	-- package size 1 byte
	assert(sz, "closed")
	sz = string.byte(sz)
	local content = assert(socket.read(fd, sz), "closed")
	return skynet.unpack(content)
end

local function pack_package(...)
	local message = skynet.packstring(...)
	local size = #message
	assert(size <= 255 , "too long")
	return string.char(size) .. message
end

-- 通知所有的slave有新的slave接入
local function report_slave(fd, slave_id, slave_addr)
	local message = pack_package("C", slave_id, slave_addr)
	local n = 0
	-- step2:通知所有已接的slave有新的slave连接
	for k,v in pairs(slave_node) do
		if v.fd ~= 0 then
			socket.write(v.fd, message)
			n = n + 1
		end
	end
	-- step3:通知新的slave需要等待n个其它slave的连接
	socket.write(fd, pack_package("W", n))
end

-- 和某个slave握手
local function handshake(fd)
	local t, slave_id, slave_addr = read_package(fd)
	assert(t=='H', "Invalid handshake type " .. t)
	assert(slave_id ~= 0 , "Invalid slave id 0")
	if slave_node[slave_id] then
		error(string.format("Slave %d already register on %s", slave_id, slave_node[slave_id].addr))
	end
	report_slave(fd, slave_id, slave_addr)
	slave_node[slave_id] = {
		fd = fd,
		id = slave_id,
		addr = slave_addr,
	}
	return slave_id , slave_addr
end

-- 处理某个slave发来的消息
local function dispatch_slave(fd)
	local t, name, address = read_package(fd)
	if t == 'R' then
		-- register name，全局的
		assert(type(address)=="number", "Invalid request")
		if not global_name[name] then
			global_name[name] = address	-- name 为全局服务名，address为服务的handle
		end
		local message = pack_package("N", name, address)
		for k,v in pairs(slave_node) do	-- 同步 给所有的slave
			socket.write(v.fd, message)
		end
	elseif t == 'Q' then
		-- query name
		local address = global_name[name]
		if address then
			socket.write(fd, pack_package("N", name, address))
		end
	else
		skynet.error("Invalid slave message type " .. t)
	end
end

-- 监控某个slave发来的消息
local function monitor_slave(slave_id, slave_address)
	local fd = slave_node[slave_id].fd
	skynet.error(string.format("Harbor %d (fd=%d) report %s", slave_id, fd, slave_address))
	while pcall(dispatch_slave, fd) do end --死循环处理slave消息
	skynet.error("slave " ..slave_id .. " is down")
	local message = pack_package("D", slave_id)
	slave_node[slave_id].fd = 0	-- 并未清除slave_node[slave_id]是为了重启后不能复用，否则id冲突
	for k,v in pairs(slave_node) do
		socket.write(v.fd, message)
	end
	socket.close(fd)
end

skynet.start(function()
	local master_addr = skynet.getenv "standalone"
	skynet.error("master listen socket " .. tostring(master_addr))
	local fd = socket.listen(master_addr)
	socket.start(fd , function(id, addr)
		skynet.error("connect from " .. addr .. " " .. id)
		socket.start(id)
		-- step1:处理slave发来的握手协议
		local ok, slave, slave_addr = pcall(handshake, id)
		if ok then
			skynet.fork(monitor_slave, slave, slave_addr)
		else
			skynet.error(string.format("disconnect fd = %d, error = %s", id, slave))
			socket.close(id)
		end
	end)
end)
