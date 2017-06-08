-- 组网工作由cmaster和cslave完成
local skynet = require "skynet"
local socket = require "skynet.socket"
require "skynet.manager"	-- import skynet.launch, ...
local table = table

local slaves = {}			-- 和本slave相连接的slave，包括主动连过来的和主动连过去的[harbor_id/slave_id] -> socket id
local connect_queue = {}	-- 初始化结束后，需要去连接的slave [slave_id] -> address
local globalname = {}		-- 全局名字
local queryname = {}
local harbor = {}			-- 命令处理函数
local harbor_service		-- harbor 服务
local monitor = {}
local monitor_master_set = {}

local function read_package(fd)
	local sz = socket.read(fd, 1)		-- 先读首字节,它描述了包的大小
	assert(sz, "closed")
	sz = string.byte(sz)
	local content = assert(socket.read(fd, sz), "closed")
	return skynet.unpack(content)
end

-- 将参数打包成size + msg
local function pack_package(...)
	local message = skynet.packstring(...)
	local size = #message
	assert(size <= 255 , "too long")
	return string.char(size) .. message	-- 首字节为大小
end

local function monitor_clear(id)
	local v = monitor[id]
	if v then
		monitor[id] = nil
		for _, v in ipairs(v) do
			v(true)
		end
	end
end

-- master通知迎新，那就去连吧
local function connect_slave(slave_id, address)
	local ok, err = pcall(function()
		if slaves[slave_id] == nil then
			local fd = assert(socket.open(address), "Can't connect to "..address)
			skynet.error(string.format("Connect to harbor %d (fd=%d), %s", slave_id, fd, address))
			slaves[slave_id] = fd
			-- 转移socket操作到harbor服务
			monitor_clear(slave_id)
			socket.abandon(fd)
			skynet.send(harbor_service, "harbor", string.format("S %d %d",fd,slave_id))
		end
	end)
	if not ok then
		skynet.error(err)
	end
end

local function ready()
	local queue = connect_queue
	connect_queue = nil
	for k,v in pairs(queue) do
		connect_slave(k,v)
	end
	for name,address in pairs(globalname) do
		skynet.redirect(harbor_service, address, "harbor", 0, "N " .. name)
	end
end

local function response_name(name)
	local address = globalname[name]
	if queryname[name] then
		local tmp = queryname[name]
		queryname[name] = nil
		for _,resp in ipairs(tmp) do
			resp(true, address)
		end
	end
end

-- 监控master发来的消息
local function monitor_master(master_fd)
	while true do
		local ok, t, id_name, address = pcall(read_package,master_fd)
		if ok then
			if t == 'C' then			-- master通知有新的slave接入到网络，本slave需要去连接这个新的slave
				if connect_queue then	-- 有connect_queue表明本服务还没有初始完毕，先存下来待初始化结束后再去连接
					connect_queue[id_name] = address
				else
					connect_slave(id_name, address)
				end
			elseif t == 'N' then	-- NAME globalname address
				globalname[id_name] = address
				response_name(id_name)
				if connect_queue == nil then
					skynet.redirect(harbor_service, address, "harbor", 0, "N " .. id_name)
				end
			elseif t == 'D' then
				local fd = slaves[id_name]
				slaves[id_name] = false
				if fd then
					monitor_clear(id_name)
					socket.close(fd)
				end
			end
		else
			skynet.error("Master disconnect")
			for _, v in ipairs(monitor_master_set) do
				v(true)
			end
			socket.close(master_fd)
			break
		end
	end
end

-- accept 一个slave 连接
local function accept_slave(fd)
	socket.start(fd)
	local id = socket.read(fd, 1)	-- 对方harbor服务发过来的handshake，为对方harbor id
	if not id then
		skynet.error(string.format("Connection (fd =%d) closed", fd))
		socket.close(fd)
		return
	end
	id = string.byte(id)
	if slaves[id] ~= nil then
		skynet.error(string.format("Slave %d exist (fd =%d)", id, fd))
		socket.close(fd)
		return
	end
	slaves[id] = fd
	-- 转移socket操作到harbor服务
	monitor_clear(id)
	socket.abandon(fd)
	skynet.error(string.format("Harbor %d connected (fd = %d)", id, fd))
	skynet.send(harbor_service, "harbor", string.format("A %d %d", fd, id))
end

-- 貌似脚本中不会处理harbor，由harbor_service处理
skynet.register_protocol {
	name = "harbor",
	id = skynet.PTYPE_HARBOR,
	pack = function(...) return ... end,
	unpack = skynet.tostring,
}

skynet.register_protocol {
	name = "text",
	id = skynet.PTYPE_TEXT,
	pack = function(...) return ... end,
	unpack = skynet.tostring,
}

local function monitor_harbor(master_fd)
	return function(session, source, command)
		-- 处理"text"协议
		local t = string.sub(command, 1, 1)
		local arg = string.sub(command, 3)
		if t == 'Q' then
			-- query name
			-- c里面发送给其它harbor但是找不到目标名字
			if globalname[arg] then
				skynet.redirect(harbor_service, globalname[arg], "harbor", 0, "N " .. arg)
			else
				socket.write(master_fd, pack_package("Q", arg))
			end
		elseif t == 'D' then
			-- harbor down
			local id = tonumber(arg)
			if slaves[id] then
				monitor_clear(id)
			end
			slaves[id] = false
		else
			skynet.error("Unknown command ", command)
		end
	end
end

-- 注册一个全局名字
-- fd是master的socket id，name是要注册的名字，handle是名字对应的服务handle
function harbor.REGISTER(fd, name, handle)
	assert(globalname[name] == nil)
	globalname[name] = handle
	response_name(name)
	socket.write(fd, pack_package("R", name, handle))
	skynet.redirect(harbor_service, handle, "harbor", 0, "N " .. name)
end

-- 监控一个 slave 是否断开，id为harbor id，如果 harbor id 对应的 slave 正常，这个 api 将阻塞。当 slave 断开时，会立刻返回
function harbor.LINK(fd, id)
	if slaves[id] then
		if monitor[id] == nil then
			monitor[id] = {}
		end
		table.insert(monitor[id], skynet.response())
	else
		skynet.ret()
	end
end

-- 监控一个 master 是否断开类似LINK
function harbor.LINKMASTER()
	table.insert(monitor_master_set, skynet.response())
end

-- 和 LINK 相反。如果 harbor id 对应的 slave 没有连接，这个 api 将阻塞，一直到它连上来才返回
function harbor.CONNECT(fd, id)
	if not slaves[id] then
		if monitor[id] == nil then
			monitor[id] = {}
		end
		table.insert(monitor[id], skynet.response())
	else
		skynet.ret()
	end
end

-- 可以用来查询全局名字或本地名字对应的服务地址
function harbor.QUERYNAME(fd, name)
	if name:byte() == 46 then	-- "." , local name
		skynet.ret(skynet.pack(skynet.localname(name)))
		return
	end
	local result = globalname[name]
	if result then
		skynet.ret(skynet.pack(result))
		return
	end
	local queue = queryname[name]
	if queue == nil then
		socket.write(fd, pack_package("Q", name))
		queue = { skynet.response() }
		queryname[name] = queue
	else
		table.insert(queue, skynet.response())
	end
end

skynet.start(function()
	local master_addr = skynet.getenv "master"
	local harbor_id = tonumber(skynet.getenv "harbor")
	local slave_address = assert(skynet.getenv "address")
	local slave_fd = socket.listen(slave_address)
	skynet.error("slave connect to master " .. tostring(master_addr))
	local master_fd = assert(socket.open(master_addr), "Can't connect to master")

	-- 见harbor.lua
	skynet.dispatch("lua", function (_,_,command,...)
		local f = assert(harbor[command])
		f(master_fd, ...)
	end)

	-- 见service_harbor.c
	skynet.dispatch("text", monitor_harbor(master_fd))

	-- 启动harbor服务
	harbor_service = assert(skynet.launch("harbor", harbor_id, skynet.self()))
	-- step1:向master发送握手协议
	local hs_message = pack_package("H", harbor_id, slave_address)
	socket.write(master_fd, hs_message)
	-- step2:收到master发过来的通知：有一大波slave将连过来
	local t, n = read_package(master_fd)
	assert(t == "W" and type(n) == "number", "slave shakehand failed")
	skynet.error(string.format("Waiting for %d harbors", n))
	skynet.fork(monitor_master, master_fd)
	if n > 0 then
		local co = coroutine.running()
		socket.start(slave_fd, function(fd, addr)
			skynet.error(string.format("New connection (fd = %d, %s)",fd, addr))
			if pcall(accept_slave,fd) then
				local s = 0
				for k,v in pairs(slaves) do
					s = s + 1
				end
				if s >= n then
					skynet.wakeup(co)
				end
			end
		end)
		skynet.wait()
	end
	socket.close(slave_fd)	-- 关闭监听端口，如果再有新节点加入网络，老节点主动去连接新节点
	skynet.error("Shakehand ready")
	skynet.fork(ready)
end)
