local driver = require "skynet.socketdriver"
local skynet = require "skynet"
local skynet_core = require "skynet.core"
local assert = assert

local socket = {}	-- api
local buffer_pool = {}	-- store all message buffer object，除了[1]表示当前free_node，后面的都是占位用，用于控制分配接收包进度
local socket_pool = setmetatable( -- store all socket object
	{},
	{ __gc = function(p)
		for id,v in pairs(p) do
			driver.close(id)
			-- don't need clear v.buffer, because buffer pool will be free at the end
			p[id] = nil
		end
	end
	}
)

local socket_message = {}

local function wakeup(s)
	local co = s.co
	if co then
		s.co = nil
		skynet.wakeup(co)
	end
end

local function suspend(s)
	assert(not s.co)				-- 不允许多个协程来suspend一个socket
	s.co = coroutine.running()		-- 保存当前运行的协程，消息到来的时候根据socket id获得s.co进而唤醒等待
	skynet.wait(s.co)
	-- 为何不在这里s.co = nil，反正在楼上的wakeup中设置也是一样
	-- wakeup closing corouting every time suspend,
	-- because socket.close() will wait last socket buffer operation before clear the buffer.
	if s.closing then			-- 如果正在关闭中(因为要等待此socket被读取完，所以分阶段关闭)，wait返回后就可以唤醒关闭携程执行接下来的关闭流程
		skynet.wakeup(s.closing)
	end
end

-- read skynet_socket.h for these macro
-- SKYNET_SOCKET_TYPE_DATA = 1
-- for tcp
-- 有数据到了，将其存入c中的数据包，再唤醒阻塞读取的协程来读取
socket_message[1] = function(id, size, data)
	local s = socket_pool[id]
	if s == nil then
		skynet.error("socket: drop package from " .. id)
		driver.drop(data, size)
		return
	end

	local sz = driver.push(s.buffer, buffer_pool, data, size)	-- 返回此socket上总的未读字节大小(之后由c去释放)
	local rr = s.read_required
	local rrt = type(rr)
	if rrt == "number" then
		-- read size
		if sz >= rr then
			-- 收到的消息足够需要的了
			s.read_required = nil
			wakeup(s)
		end
	else
		-- 如果收到的缓冲超过限定的大小(防止恶意攻击)
		if s.buffer_limit and sz > s.buffer_limit then
			skynet.error(string.format("socket buffer overflow: fd=%d size=%d", id , sz))
			driver.clear(s.buffer,buffer_pool)
			driver.close(id)
			return
		end
		if rrt == "string" then
			-- read line,nil表示仅仅是检测是否含有分隔符(目前只支持\n)
			if driver.readline(s.buffer,nil,rr) then	
				s.read_required = nil
				wakeup(s)
			end
		end
		-- 还可能是true，比如readall，这样的话，读到数据是不会放行的，比如等待close或者error
	end
end

-- SKYNET_SOCKET_TYPE_CONNECT = 2
-- 可以开始通信了
socket_message[2] = function(id, _ , addr)
	local s = socket_pool[id]
	if s == nil then
		return
	end
	-- log remote addr
	s.connected = true
	wakeup(s)
end

-- SKYNET_SOCKET_TYPE_CLOSE = 3
-- 因为发送异常或者主动关闭，
socket_message[3] = function(id)
	local s = socket_pool[id]
	if s == nil then
		return
	end
	s.connected = false
	wakeup(s)
end

-- SKYNET_SOCKET_TYPE_ACCEPT = 4
-- 新连上一个客户端, newid为此连接id
socket_message[4] = function(id, newid, addr)
	local s = socket_pool[id]
	if s == nil then
		driver.close(newid)
		return
	end
	s.callback(newid, addr)
end

-- SKYNET_SOCKET_TYPE_ERROR = 5
-- 发生异常
socket_message[5] = function(id, _, err)
	local s = socket_pool[id]
	if s == nil then
		skynet.error("socket: error on unknown", id, err)
		return
	end
	if s.connected then
		skynet.error("socket: error on", id, err)
	elseif s.connecting then
		s.connecting = err
	end
	s.connected = false
	driver.shutdown(id)	-- 还会造成发送SKYNET_SOCKET_TYPE_CLOSE

	wakeup(s)
end

-- SKYNET_SOCKET_TYPE_UDP = 6
socket_message[6] = function(id, size, data, address)
	local s = socket_pool[id]
	if s == nil or s.callback == nil then
		skynet.error("socket: drop udp package from " .. id)
		driver.drop(data, size)
		return
	end
	local str = skynet.tostring(data, size)
	skynet_core.trash(data, size)
	s.callback(str, address)
end

local function default_warning(id, size)
	local s = socket_pool[id]
	if not s then
		return
	end
	skynet.error(string.format("WARNING: %d K bytes need to send out (fd = %d)", size, id))
end

-- SKYNET_SOCKET_TYPE_WARNING
socket_message[7] = function(id, size)
	local s = socket_pool[id]
	if s then
		local warning = s.on_warning or default_warning
		warning(id, size)
	end
end

skynet.register_protocol {
	name = "socket",
	id = skynet.PTYPE_SOCKET,	-- PTYPE_SOCKET = 6
	unpack = driver.unpack,		-- socket只解c发来的请求(session = 0, source = 0)，而无需直接发送给其它service所以不需要pack
	dispatch = function (_, _, t, ...)	-- _,_,表示session和source,两者都是0, t是message->type(SKYNET_SOCKET_TYPE_XXXX)，见skynet_socket_message
		socket_message[t](...)	-- ...是unpack之后[1]之后的东西(id, ud, string or lightuserdata, string for udp)，[1]是t
	end
}

-- 阻塞函数
-- 创建一个socket对象，然后等待连接建立成功
local function connect(id, func)
	local newbuffer
	if func == nil then
		-- 非listen socket，创建收发缓冲
		newbuffer = driver.buffer()
	end
	local s = {
		id = id,					-- socket id
		buffer = newbuffer,			-- 保存此socket所收到的数据包
		connected = false,			-- 已经连接标识
		connecting = true,			-- 正在连接标识
		read_required = false,		-- 表示要求读多少字节
		co = false,					-- suspend的时候保存当前协程，以便之后收到消息能够唤醒
		callback = func,			-- 新客户端连接上服务端的回调
		protocol = "TCP",
		--closing = nil,			-- 关闭过程中，其它正在操作此socket的协程，需要等待其操作完才关闭
	}
	assert(not socket_pool[id], "socket is not closed")
	socket_pool[id] = s
	suspend(s)						-- [S]等待SKYNET_SOCKET_TYPE_ACCEPT [C]等待SKYNET_SOCKET_TYPE_CONNECT
	local err = s.connecting
	s.connecting = nil
	if s.connected then
		return id
	else
		socket_pool[id] = nil
		return nil, err
	end
end

-- 类型：[C] 阻塞函数，连接成功或者失败返回
-- 描述：客户主动连接指定地址和端口
-- 返回：成功返回此连接的socket id，否则返回nil
function socket.open(addr, port)
	local id = driver.connect(addr,port)	-- id(socket id)和此context绑定了
	return connect(id)
end

-- 开始监听os_fd的io
function socket.bind(os_fd)
	local id = driver.bind(os_fd)
	return connect(id)
end

-- 监听stdin
function socket.stdin()
	return socket.bind(0)
end

-- 类型：[S] 立即函数
-- 1.对于listen的socket来说，start是开始监控客户端连接事件(plisten->listen)，传入的func在客户端连上的时候调用
-- 2.对于accept的socket来说，start是开始监控和客户端的数据交换(paccept->connected)
-- 返回：成功返回传入id，否则返回nil
function socket.start(id, func)
	driver.start(id)
	return connect(id, func)
end

function socket.shutdown(id)
	local s = socket_pool[id]
	if s then
		driver.clear(s.buffer,buffer_pool)
		-- the framework would send SKYNET_SOCKET_TYPE_CLOSE , need close(id) later
		driver.shutdown(id)
	end
end

function socket.close_fd(id)
	assert(socket_pool[id] == nil,"Use socket.close instead")
	driver.close(id)
end

-- 类型：[C/S] 阻塞
-- 描述：关闭一个连接，这个 API 有可能阻塞住执行流。因为如果有其它 coroutine 正在阻塞读这个 id 对应的连接，会先驱使读操作结束，close 操作才返回
function socket.close(id)
	local s = socket_pool[id]
	if s == nil then
		return
	end
	if s.connected then
		driver.close(id)
		-- notice: call socket.close in __gc should be carefully,
		-- because skynet.wait never return in __gc, so driver.clear may not be called
		if s.co then
			-- 可能有其它协程在读它
			-- suspend的时候才会设置co，等suspend结束的时候，才能继续执行，因此设置closing等suspend继续运行才放行
			-- reading this socket on another coroutine, so don't shutdown (clear the buffer) immediately
			-- wait reading coroutine read the buffer.
			assert(not s.closing)	-- 不能有2个人同时关闭它
			s.closing = coroutine.running()
			skynet.wait(s.closing)
		else
			suspend(s)
		end
		s.connected = false	-- 实际上driver.close会通知一个close事件，在处理close事件的时候已经设置了false
	end
	driver.clear(s.buffer,buffer_pool)
	assert(s.lock == nil or next(s.lock) == nil)
	socket_pool[id] = nil
end

-- 类型：[C/S] 阻塞函数
-- 描述：从指定socket上读sz大小的数据。
-- 返回：成功读到sz字节数据，则返回数据字符串;如果因为异常导致没读到要求字符串则返回false + 读到的字符串
function socket.read(id, sz)
	local s = socket_pool[id]
	assert(s)
	if sz == nil then
		-- read some bytes
		local ret = driver.readall(s.buffer, buffer_pool)
		if ret ~= "" then
			return ret
		end

		-- 还未连接
		if not s.connected then
			return false, ret
		end
		assert(not s.read_required)
		s.read_required = 0	-- 需要至少0字节，说明只要有数据就OK
		suspend(s)	-- 挂起来等数据到达
		ret = driver.readall(s.buffer, buffer_pool)
		if ret ~= "" then
			return ret
		else
			return false, ret	-- 断开了
		end
	end

	local ret = driver.pop(s.buffer, buffer_pool, sz)
	if ret then
		return ret
	end
	if not s.connected then
		return false, driver.readall(s.buffer, buffer_pool)
	end

	assert(not s.read_required)
	s.read_required = sz
	suspend(s)
	ret = driver.pop(s.buffer, buffer_pool, sz)
	if ret then
		return ret
	else
		return false, driver.readall(s.buffer, buffer_pool)
	end
end

--[[
	从一个 socket 上读所有的数据，直到 socket 主动断开，或在其它 coroutine 用 socket.close 关闭它。
	用于短连接？
]]
-- 阻塞函数
function socket.readall(id)
	local s = socket_pool[id]
	assert(s)
	if not s.connected then
		local r = driver.readall(s.buffer, buffer_pool)
		return r ~= "" and r
	end
	assert(not s.read_required)
	s.read_required = true
	suspend(s)	-- 挂起来直到断开或者错误发生，因为read_required设置了这个特殊的值
	assert(s.connected == false)
	return driver.readall(s.buffer, buffer_pool)
end

--[[
	从一个 socket 上读一行数据。sep 指行分割符。默认的 sep 为 "\n"。读到的字符串是不包含这个分割符的。
	阻塞的
]]
function socket.readline(id, sep)
	sep = sep or "\n"
	local s = socket_pool[id]
	assert(s)
	local ret = driver.readline(s.buffer, buffer_pool, sep)
	if ret then
		return ret
	end
	if not s.connected then
		return false, driver.readall(s.buffer, buffer_pool)
	end
	assert(not s.read_required)
	s.read_required = sep
	suspend(s)
	if s.connected then
		return driver.readline(s.buffer, buffer_pool, sep)
	else
		return false, driver.readall(s.buffer, buffer_pool)
	end
end

-- 等待一个 socket 可读
function socket.block(id)
	local s = socket_pool[id]
	if not s or not s.connected then
		return false
	end
	assert(not s.read_required)
	s.read_required = 0	-- 只要有数据就行，不要求大小
	suspend(s)
	return s.connected
end

socket.write = assert(driver.send)		-- 把一个字符串置入正常的写队列，skynet 框架会在 socket 可写时发送它
socket.lwrite = assert(driver.lsend)
socket.header = assert(driver.header) -- 取包头(字节数)

function socket.invalid(id)
	return socket_pool[id] == nil
end

function socket.disconnected(id)
	local s = socket_pool[id]
	if s then
		return not(s.connected or s.connecting)
	end
end

-- 类型：[S] 立即函数
-- 描述：监听指定地址和端口，返回后socket处于plisten状态，需要调用socket.start之后才能accept客户端连接
-- 返回：监听socket id
function socket.listen(host, port, backlog)
	if port == nil then
		host, port = string.match(host, "([^:]+):(.+)$")
		port = tonumber(port)
	end
	return driver.listen(host, port, backlog)
end

-- 对一个socket加锁，阻止多个协程同时进入
function socket.lock(id)
	local s = socket_pool[id]
	assert(s)
	local lock_set = s.lock
	if not lock_set then
		lock_set = {}
		s.lock = lock_set
	end
	if #lock_set == 0 then					-- 第一个拥有锁的人可以继续走
		lock_set[1] = true
	else
		local co = coroutine.running()		-- 第二个人只能等待
		table.insert(lock_set, co)
		skynet.wait(co)
	end
end

function socket.unlock(id)
	local s = socket_pool[id]
	assert(s)
	local lock_set = assert(s.lock)
	table.remove(lock_set,1)
	local co = lock_set[1]					-- 唤醒第一个等待的人
	if co then
		skynet.wakeup(co)
	end
end

-- abandon use to forward socket id to other service
-- you must call socket.start(id) later in other service
-- 清除 socket id 在本服务内的数据结构，但并不关闭这个 socket 。
-- 这可以用于你把 id 发送给其它服务，以转交 socket 的控制权
function socket.abandon(id)
	local s = socket_pool[id]
	if s then
		driver.clear(s.buffer,buffer_pool)
		s.connected = false
		wakeup(s)
		socket_pool[id] = nil
	end
end

-- 设置接收缓冲的大小，如果超出会断开连接
function socket.limit(id, limit)
	local s = assert(socket_pool[id])
	s.buffer_limit = limit
end

---------------------- UDP

local function create_udp_object(id, cb)
	assert(not socket_pool[id], "socket is not closed")
	socket_pool[id] = {
		id = id,
		connected = true,
		protocol = "UDP",
		callback = cb,	-- 收到消息的回调
	}
end

-- 创建一个 udp handle
-- callback 回调函数，当这个 handle 收到 udp 消息时，callback 函数将被触发
-- host 绑定的 ip，默认为 ipv4 的 0.0.0.0 
-- port 绑定的 port，默认为 0，这表示仅创建一个 udp handle （用于发送），但不绑定固定端口
function socket.udp(callback, host, port)
	local id = driver.udp(host, port)	-- 不用连接，仅仅是绑定本地端口用于收发数据，所以也不用suspend
	create_udp_object(id, callback)
	return id
end

-- 给一个 udp handle 设置一个默认的发送目的地址
function socket.udp_connect(id, addr, port, callback)
	local obj = socket_pool[id]
	if obj then
		assert(obj.protocol == "UDP")
		if callback then
			obj.callback = callback
		end
	else
		create_udp_object(id, callback)
	end
	driver.udp_connect(id, addr, port)
end

-- 向一个网络地址发送一个数据包 id, from, data
-- 第二个参数 from 即是一个网络地址，这是一个 string ，通常由 callback 函数生成，你无法自己构建一个地址串，但你可以把 callback 函数中得到的地址串保存起来以后使用。发送的内容是一个字符串 data 。
socket.sendto = assert(driver.udp_send)
-- 这个字符串可以用 socket.udp_address(from) : address port 转换为可读的 ip 地址和端口，用于记录。
socket.udp_address = assert(driver.udp_address)

function socket.warning(id, callback)
	local obj = socket_pool[id]
	assert(obj)
	obj.on_warning = callback
end

return socket
