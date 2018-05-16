local skynet = require "skynet"
local socket = require "skynet.socket"
local socketdriver = require "skynet.socketdriver"

-- channel support auto reconnect , and capture socket error in request/response transaction
-- { host = "", port = , auth = function(so) , response = function(so) session, data }

local socket_channel = {}
local channel = {}
local channel_socket = {}	-- [1] 是 socket id
local channel_meta = { __index = channel }
local channel_socket_meta = {
	__index = channel_socket,
	__gc = function(cs)
		local fd = cs[1]
		cs[1] = false
		if fd then
			socket.shutdown(fd)
		end
	end
}

local socket_error = setmetatable({}, {__tostring = function() return "[Error: socket]" end })	-- alias for error object
socket_channel.error = socket_error

-- 创建一个 channel 对象
function socket_channel.channel(desc)
	local c = {
		__host = assert(desc.host),
		__port = assert(desc.port),
		__backup = desc.backup,			-- 备用地址列表
		__auth = desc.auth,
		__response = desc.response,		-- It's for session mode, 用于处理 mongodb 的返回结果，返回处理结果和相应 session 供后续处理
		__request = {},					-- [i] = response，用于order模式，表明回应回调函数队列
		__thread = {},					-- [sesion/i] = co，用于session/order模式，表明请求对应的挂起协程，用于数据到达的时候唤醒
		__result = {},					-- [co] = result，用于session/order模式，表明协程处理结果是否异常
		__result_data = {},				-- [co] = {data}，用于session模式，表明回应的处理结果
		__connecting = {},				-- 正在连接的协程，如果有多个服务请求连接，只有一个真正尝试，其余的都在wait
		__sock = false,					-- 连接成功后__sock为table，是fd(socket id)的封装，[1]为fd，__index = channel_socket_meta，使其有读写功能
		__closed = false,				-- true为正在关闭socket
		__authcoroutine = false,
		__nodelay = desc.nodelay,
	}

	return setmetatable(c, channel_meta)
end

local function close_channel_socket(self)
	if self.__sock then
		local so = self.__sock
		self.__sock = false
		-- never raise error
		pcall(socket.close,so[1])
	end
end

local function wakeup_all(self, errmsg)
	if self.__response then
		for k,co in pairs(self.__thread) do
			self.__thread[k] = nil
			self.__result[co] = socket_error
			self.__result_data[co] = errmsg
			skynet.wakeup(co)
		end
	else
		for i = 1, #self.__request do
			self.__request[i] = nil
		end
		for i = 1, #self.__thread do
			local co = self.__thread[i]
			self.__thread[i] = nil
			if co then	-- ignore the close signal
				self.__result[co] = socket_error
				self.__result_data[co] = errmsg
				skynet.wakeup(co)
			end
		end
	end
end

local function exit_thread(self)
	local co = coroutine.running()
	if self.__dispatch_thread == co then
		self.__dispatch_thread = nil
		local connecting = self.__connecting_thread
		if connecting then
			skynet.wakeup(connecting)
		end
	end
end

-- 开启一个线程来处理 server 返回的结果
local function dispatch_by_session(self)
	local response = self.__response
	-- response() return session
	while self.__sock do
		local ok , session, result_ok, result_data, padding = pcall(response, self.__sock)	-- 阻塞等待任何回应，padding表示还有后续数据
		if ok and session then
			local co = self.__thread[session]	-- 看是响应哪个请求，相应等待的协程可以放行了
			if co then
				if padding and result_ok then
					-- If padding is true, append result_data to a table (self.__result_data[co])
					local result = self.__result_data[co] or {}
					self.__result_data[co] = result
					table.insert(result, result_data)
				else
					-- 收集完成，唤醒消费者
					self.__thread[session] = nil
					self.__result[co] = result_ok
					if result_ok and self.__result_data[co] then
						-- 正确处理
						table.insert(self.__result_data[co], result_data)
					else
						-- 出现异常
						self.__result_data[co] = result_data
					end
					skynet.wakeup(co)
				end
			else
				self.__thread[session] = nil
				skynet.error("socket: unknown session :", session)
			end
		else
			close_channel_socket(self)
			local errormsg
			if session ~= socket_error then
				errormsg = session
			end
			wakeup_all(self, errormsg)
		end
	end
	exit_thread(self)
end

local function pop_response(self)
	while true do
		local func,co = table.remove(self.__request, 1), table.remove(self.__thread, 1)
		if func then
			return func, co
		end
		self.__wait_response = coroutine.running()
		skynet.wait(self.__wait_response)
	end
end

-- response 对于order mode 类型来说是应答 callback，一个请求顺序对应一个应答
--			对于session 类型来说是 session，根据 session 来找到原请求
local function push_response(self, response, co)
	if self.__response then
		-- response is session
		self.__thread[response] = co
	else
		-- response is a function, push it to __request
		table.insert(self.__request, response)
		table.insert(self.__thread, co)
		if self.__wait_response then	-- 等待回应处理函数
			skynet.wakeup(self.__wait_response)
			self.__wait_response = nil
		end
	end
end

local function get_response(func, sock)
	local result_ok, result_data, padding = func(sock)
	if result_ok and padding then
		local result = { result_data }
		local index = 2
		repeat
			result_ok, result_data, padding = func(sock)
			if not result_ok then
				return result_ok, result_data
			end
			result[index] = result_data
			index = index + 1
		until not padding
		return true, result
	else
		return result_ok, result_data
	end
end

-- 开启一个线程来处理 server 返回的结果，另外一个是 dispatch_by_session
local function dispatch_by_order(self)
	while self.__sock do
		local func, co = pop_response(self)
		if not co then
			-- close signal
			wakeup_all(self, "channel_closed")
			break
		end
		local ok, result_ok, result_data = pcall(get_response, func, self.__sock)
		if ok then
			-- 没有后续数据了，可以唤醒之前因为请求挂起来的协程
			self.__result[co] = result_ok
			if result_ok and self.__result_data[co] then
				table.insert(self.__result_data[co], result_data)
			else
				self.__result_data[co] = result_data
			end
			skynet.wakeup(co)
		else
			close_channel_socket(self)
			local errmsg
			if result_ok ~= socket_error then
				errmsg = result_ok
			end
			self.__result[co] = socket_error
			self.__result_data[co] = errmsg
			skynet.wakeup(co)
			wakeup_all(self, errmsg)
		end
	end
	exit_thread(self)
end

local function dispatch_function(self)
	if self.__response then
		-- sission mode
		return dispatch_by_session
	else
		-- order mode
		return dispatch_by_order
	end
end

local function connect_backup(self)
	if self.__backup then
		for _, addr in ipairs(self.__backup) do
			local host, port
			if type(addr) == "table" then
				host, port = addr.host, addr.port
			else
				host = addr
				port = self.__port
			end
			skynet.error("socket: connect to backup host", host, port)
			local fd = socket.open(host, port)
			if fd then
				self.__host = host
				self.__port = port
				return fd
			end
		end
	end
end

local function connect_once(self)
	if self.__closed then
		return false
	end
	assert(not self.__sock and not self.__authcoroutine)
	local fd,err = socket.open(self.__host, self.__port)
	if not fd then
		-- 连接不成功会试图去连接备份地址
		fd = connect_backup(self)
		if not fd then
			return false, err
		end
	end
	if self.__nodelay then
		socketdriver.nodelay(fd)
	end

	self.__sock = setmetatable( {fd} , channel_socket_meta )			-- self._sock[1] 为fd即 socket id
	self.__dispatch_thread = skynet.fork(dispatch_function(self), self) -- 开启一个协程循环来处理请求

	if self.__auth then
		self.__authcoroutine = coroutine.running()
		local ok , message = pcall(self.__auth, self)
		if not ok then
			close_channel_socket(self)
			if message ~= socket_error then
				self.__authcoroutine = false
				skynet.error("socket: auth failed", message)
			end
		end
		self.__authcoroutine = false
		if ok and not self.__sock then
			-- auth may change host, so connect again
			return connect_once(self)
		end
		return ok
	end

	return true
end

-- once 表示只尝试连接一次，否则会频繁去连
local function try_connect(self , once)
	local t = 0
	while not self.__closed do
		local ok, err = connect_once(self)
		if ok then
			if not once then
				skynet.error("socket: connect to", self.__host, self.__port)
			end
			return
		elseif once then
			return err
		else
			skynet.error("socket: connect", err)
		end
		if t > 1000 then
			skynet.error("socket: try to reconnect", self.__host, self.__port)
			skynet.sleep(t)
			t = 0
		else
			skynet.sleep(t)
		end
		t = t + 100
	end
end

local function check_connection(self)
	if self.__sock then
		if socket.disconnected(self.__sock[1]) then
			-- closed by peer
			skynet.error("socket: disconnect detected ", self.__host, self.__port)
			close_channel_socket(self)
			return
		end
		local authco = self.__authcoroutine
		if not authco then
			return true
		end
		if authco == coroutine.running() then
			-- authing
			return true
		end
	end
	if self.__closed then
		return false
	end
end

local function block_connect(self, once)
	local r = check_connection(self)
	if r ~= nil then
		return r
	end
	local err

	if #self.__connecting > 0 then
		-- connecting in other coroutine
		local co = coroutine.running()
		table.insert(self.__connecting, co)
		skynet.wait(co)
	else
		self.__connecting[1] = true
		err = try_connect(self, once)
		self.__connecting[1] = nil
		for i=2, #self.__connecting do
			-- 连接成功唤醒所有等待连接的协程
			local co = self.__connecting[i]
			self.__connecting[i] = nil
			skynet.wakeup(co)
		end
	end

	r = check_connection(self)
	if r == nil then
		skynet.error(string.format("Connect to %s:%d failed (%s)", self.__host, self.__port, err))
		error(socket_error)
	else
		return r
	end
end

function channel:connect(once)
	if self.__closed then
		if self.__dispatch_thread then
			-- closing, wait
			assert(self.__connecting_thread == nil, "already connecting")
			local co = coroutine.running()
			self.__connecting_thread = co
			skynet.wait(co)
			self.__connecting_thread = nil
		end
		self.__closed = false
	end

	return block_connect(self, once)
end

-- response 对于order mode 类型来说是应答callback，一个请求顺序对应一个应答
--			对于session类型来说是session，根据session来找到原请求
local function wait_for_response(self, response)
	local co = coroutine.running()
	push_response(self, response, co)	-- 压入回调
	skynet.wait(co)

	local result = self.__result[co]
	self.__result[co] = nil
	local result_data = self.__result_data[co]
	self.__result_data[co] = nil

	if result == socket_error then
		if result_data then
			error(result_data)
		else
			error(socket_error)
		end
	else
		assert(result, result_data)
		return result_data
	end
end

local socket_write = socket.write
local socket_lwrite = socket.lwrite

local function sock_err(self)
	close_channel_socket(self)
	wakeup_all(self)
	error(socket_error)
end

-- request 为请求内容
-- response 是一个 function ，用来收取回应包
-- response 对于order mode 类型来说是应答callback，一个请求顺序对应一个应答
--			对于session类型来说是session，根据session来找到原请求
-- 阻塞函数，请求并等待回应
function channel:request(request, response, padding)
	assert(block_connect(self, true))	-- connect once
	local fd = self.__sock[1]

	if padding then
		-- padding may be a table, to support multi part request
		-- multi part request use low priority socket write
		-- now socket_lwrite returns as socket_write
		if not socket_lwrite(fd , request) then
			sock_err(self)
		end
		for _,v in ipairs(padding) do
			if not socket_lwrite(fd, v) then
				sock_err(self)
			end
		end
	else
		if not socket_write(fd , request) then
			sock_err(self)
		end
	end

	if response == nil then
		-- no response
		return
	end

	-- 阻塞等待回应
	return wait_for_response(self, response)
end

-- 用来单向接收一个包
--[[
	channel:request(req)
	local resp = channel:response(dispatch)

	-- 等价于
	local resp = channel:request(req, dispatch)
]]
function channel:response(response)
	assert(block_connect(self))

	return wait_for_response(self, response)
end

function channel:close()
	if not self.__closed then
		local thread = self.__dispatch_thread
		self.__closed = true
		close_channel_socket(self)
		if not self.__response and self.__dispatch_thread == thread and thread then
			-- dispatch by order, send close signal to dispatch thread
			push_response(self, true, false)	-- (true, false) is close signal
		end
	end
end

function channel:changehost(host, port)
	self.__host = host
	if port then
		self.__port = port
	end
	if not self.__closed then
		close_channel_socket(self)
	end
end

function channel:changebackup(backup)
	self.__backup = backup
end

channel_meta.__gc = channel.close

local function wrapper_socket_function(f)
	return function(self, ...)
		local result = f(self[1], ...)	-- self[1] 是 socket id
		if not result then
			error(socket_error)
		else
			return result
		end
	end
end

channel_socket.read = wrapper_socket_function(socket.read)
channel_socket.readline = wrapper_socket_function(socket.readline)

return socket_channel
