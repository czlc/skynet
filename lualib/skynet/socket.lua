local driver = require "skynet.socketdriver"
local skynet = require "skynet"
local skynet_core = require "skynet.core"
local assert = assert

local socket = {}	-- api
local buffer_pool = {}	-- store all message buffer object������[1]��ʾ��ǰfree_node������Ķ���ռλ�ã����ڿ��Ʒ�����հ�����
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
	assert(not s.co)				-- ��������Э����suspendһ��socket
	s.co = coroutine.running()		-- ���浱ǰ���е�Э�̣���Ϣ������ʱ�����socket id���s.co�������ѵȴ�
	skynet.wait(s.co)
	-- Ϊ�β�������s.co = nil��������¥�ϵ�wakeup������Ҳ��һ��
	-- wakeup closing corouting every time suspend,
	-- because socket.close() will wait last socket buffer operation before clear the buffer.
	if s.closing then			-- ������ڹر���(��ΪҪ�ȴ���socket����ȡ�꣬���Էֽ׶ιر�)��wait���غ�Ϳ��Ի��ѹر�Я��ִ�н������Ĺر�����
		skynet.wakeup(s.closing)
	end
end

-- read skynet_socket.h for these macro
-- SKYNET_SOCKET_TYPE_DATA = 1
-- for tcp
-- �����ݵ��ˣ��������c�е����ݰ����ٻ���������ȡ��Э������ȡ
socket_message[1] = function(id, size, data)
	local s = socket_pool[id]
	if s == nil then
		skynet.error("socket: drop package from " .. id)
		driver.drop(data, size)
		return
	end

	local sz = driver.push(s.buffer, buffer_pool, data, size)	-- ���ش�socket���ܵ�δ���ֽڴ�С(֮����cȥ�ͷ�)
	local rr = s.read_required
	local rrt = type(rr)
	if rrt == "number" then
		-- read size
		if sz >= rr then
			-- �յ�����Ϣ�㹻��Ҫ����
			s.read_required = nil
			wakeup(s)
		end
	else
		-- ����յ��Ļ��峬���޶��Ĵ�С(��ֹ���⹥��)
		if s.buffer_limit and sz > s.buffer_limit then
			skynet.error(string.format("socket buffer overflow: fd=%d size=%d", id , sz))
			driver.clear(s.buffer,buffer_pool)
			driver.close(id)
			return
		end
		if rrt == "string" then
			-- read line,nil��ʾ�����Ǽ���Ƿ��зָ���(Ŀǰֻ֧��\n)
			if driver.readline(s.buffer,nil,rr) then	
				s.read_required = nil
				wakeup(s)
			end
		end
		-- ��������true������readall�������Ļ������������ǲ�����еģ�����ȴ�close����error
	end
end

-- SKYNET_SOCKET_TYPE_CONNECT = 2
-- ���Կ�ʼͨ����
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
-- ��Ϊ�����쳣���������رգ�
socket_message[3] = function(id)
	local s = socket_pool[id]
	if s == nil then
		return
	end
	s.connected = false
	wakeup(s)
end

-- SKYNET_SOCKET_TYPE_ACCEPT = 4
-- ������һ���ͻ���, newidΪ������id
socket_message[4] = function(id, newid, addr)
	local s = socket_pool[id]
	if s == nil then
		driver.close(newid)
		return
	end
	s.callback(newid, addr)
end

-- SKYNET_SOCKET_TYPE_ERROR = 5
-- �����쳣
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
	driver.shutdown(id)	-- ������ɷ���SKYNET_SOCKET_TYPE_CLOSE

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
	unpack = driver.unpack,		-- socketֻ��c����������(session = 0, source = 0)��������ֱ�ӷ��͸�����service���Բ���Ҫpack
	dispatch = function (_, _, t, ...)	-- _,_,��ʾsession��source,���߶���0, t��message->type(SKYNET_SOCKET_TYPE_XXXX)����skynet_socket_message
		socket_message[t](...)	-- ...��unpack֮��[1]֮��Ķ���(id, ud, string or lightuserdata, string for udp)��[1]��t
	end
}

-- ��������
-- ����һ��socket����Ȼ��ȴ����ӽ����ɹ�
local function connect(id, func)
	local newbuffer
	if func == nil then
		-- ��listen socket�������շ�����
		newbuffer = driver.buffer()
	end
	local s = {
		id = id,					-- socket id
		buffer = newbuffer,			-- �����socket���յ������ݰ�
		connected = false,			-- �Ѿ����ӱ�ʶ
		connecting = true,			-- �������ӱ�ʶ
		read_required = false,		-- ��ʾҪ��������ֽ�
		co = false,					-- suspend��ʱ�򱣴浱ǰЭ�̣��Ա�֮���յ���Ϣ�ܹ�����
		callback = func,			-- �¿ͻ��������Ϸ���˵Ļص�
		protocol = "TCP",
		--closing = nil,			-- �رչ����У��������ڲ�����socket��Э�̣���Ҫ�ȴ��������Źر�
	}
	assert(not socket_pool[id], "socket is not closed")
	socket_pool[id] = s
	suspend(s)						-- [S]�ȴ�SKYNET_SOCKET_TYPE_ACCEPT [C]�ȴ�SKYNET_SOCKET_TYPE_CONNECT
	local err = s.connecting
	s.connecting = nil
	if s.connected then
		return id
	else
		socket_pool[id] = nil
		return nil, err
	end
end

-- ���ͣ�[C] �������������ӳɹ�����ʧ�ܷ���
-- �������ͻ���������ָ����ַ�Ͷ˿�
-- ���أ��ɹ����ش����ӵ�socket id�����򷵻�nil
function socket.open(addr, port)
	local id = driver.connect(addr,port)	-- id(socket id)�ʹ�context����
	return connect(id)
end

-- ��ʼ����os_fd��io
function socket.bind(os_fd)
	local id = driver.bind(os_fd)
	return connect(id)
end

-- ����stdin
function socket.stdin()
	return socket.bind(0)
end

-- ���ͣ�[S] ��������
-- 1.����listen��socket��˵��start�ǿ�ʼ��ؿͻ��������¼�(plisten->listen)�������func�ڿͻ������ϵ�ʱ�����
-- 2.����accept��socket��˵��start�ǿ�ʼ��غͿͻ��˵����ݽ���(paccept->connected)
-- ���أ��ɹ����ش���id�����򷵻�nil
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

-- ���ͣ�[C/S] ����
-- �������ر�һ�����ӣ���� API �п�������סִ��������Ϊ��������� coroutine ������������� id ��Ӧ�����ӣ�������ʹ������������close �����ŷ���
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
			-- ����������Э���ڶ���
			-- suspend��ʱ��Ż�����co����suspend������ʱ�򣬲��ܼ���ִ�У��������closing��suspend�������вŷ���
			-- reading this socket on another coroutine, so don't shutdown (clear the buffer) immediately
			-- wait reading coroutine read the buffer.
			assert(not s.closing)	-- ������2����ͬʱ�ر���
			s.closing = coroutine.running()
			skynet.wait(s.closing)
		else
			suspend(s)
		end
		s.connected = false	-- ʵ����driver.close��֪ͨһ��close�¼����ڴ���close�¼���ʱ���Ѿ�������false
	end
	driver.clear(s.buffer,buffer_pool)
	assert(s.lock == nil or next(s.lock) == nil)
	socket_pool[id] = nil
end

-- ���ͣ�[C/S] ��������
-- ��������ָ��socket�϶�sz��С�����ݡ�
-- ���أ��ɹ�����sz�ֽ����ݣ��򷵻������ַ���;�����Ϊ�쳣����û����Ҫ���ַ����򷵻�false + �������ַ���
function socket.read(id, sz)
	local s = socket_pool[id]
	assert(s)
	if sz == nil then
		-- read some bytes
		local ret = driver.readall(s.buffer, buffer_pool)
		if ret ~= "" then
			return ret
		end

		-- ��δ����
		if not s.connected then
			return false, ret
		end
		assert(not s.read_required)
		s.read_required = 0	-- ��Ҫ����0�ֽڣ�˵��ֻҪ�����ݾ�OK
		suspend(s)	-- �����������ݵ���
		ret = driver.readall(s.buffer, buffer_pool)
		if ret ~= "" then
			return ret
		else
			return false, ret	-- �Ͽ���
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
	��һ�� socket �϶����е����ݣ�ֱ�� socket �����Ͽ����������� coroutine �� socket.close �ر�����
	���ڶ����ӣ�
]]
-- ��������
function socket.readall(id)
	local s = socket_pool[id]
	assert(s)
	if not s.connected then
		local r = driver.readall(s.buffer, buffer_pool)
		return r ~= "" and r
	end
	assert(not s.read_required)
	s.read_required = true
	suspend(s)	-- ������ֱ���Ͽ����ߴ���������Ϊread_required��������������ֵ
	assert(s.connected == false)
	return driver.readall(s.buffer, buffer_pool)
end

--[[
	��һ�� socket �϶�һ�����ݡ�sep ָ�зָ����Ĭ�ϵ� sep Ϊ "\n"���������ַ����ǲ���������ָ���ġ�
	������
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

-- �ȴ�һ�� socket �ɶ�
function socket.block(id)
	local s = socket_pool[id]
	if not s or not s.connected then
		return false
	end
	assert(not s.read_required)
	s.read_required = 0	-- ֻҪ�����ݾ��У���Ҫ���С
	suspend(s)
	return s.connected
end

socket.write = assert(driver.send)		-- ��һ���ַ�������������д���У�skynet ��ܻ��� socket ��дʱ������
socket.lwrite = assert(driver.lsend)
socket.header = assert(driver.header) -- ȡ��ͷ(�ֽ���)

function socket.invalid(id)
	return socket_pool[id] == nil
end

function socket.disconnected(id)
	local s = socket_pool[id]
	if s then
		return not(s.connected or s.connecting)
	end
end

-- ���ͣ�[S] ��������
-- ����������ָ����ַ�Ͷ˿ڣ����غ�socket����plisten״̬����Ҫ����socket.start֮�����accept�ͻ�������
-- ���أ�����socket id
function socket.listen(host, port, backlog)
	if port == nil then
		host, port = string.match(host, "([^:]+):(.+)$")
		port = tonumber(port)
	end
	return driver.listen(host, port, backlog)
end

-- ��һ��socket��������ֹ���Э��ͬʱ����
function socket.lock(id)
	local s = socket_pool[id]
	assert(s)
	local lock_set = s.lock
	if not lock_set then
		lock_set = {}
		s.lock = lock_set
	end
	if #lock_set == 0 then					-- ��һ��ӵ�������˿��Լ�����
		lock_set[1] = true
	else
		local co = coroutine.running()		-- �ڶ�����ֻ�ܵȴ�
		table.insert(lock_set, co)
		skynet.wait(co)
	end
end

function socket.unlock(id)
	local s = socket_pool[id]
	assert(s)
	local lock_set = assert(s.lock)
	table.remove(lock_set,1)
	local co = lock_set[1]					-- ���ѵ�һ���ȴ�����
	if co then
		skynet.wakeup(co)
	end
end

-- abandon use to forward socket id to other service
-- you must call socket.start(id) later in other service
-- ��� socket id �ڱ������ڵ����ݽṹ���������ر���� socket ��
-- ������������ id ���͸�����������ת�� socket �Ŀ���Ȩ
function socket.abandon(id)
	local s = socket_pool[id]
	if s then
		driver.clear(s.buffer,buffer_pool)
		s.connected = false
		wakeup(s)
		socket_pool[id] = nil
	end
end

-- ���ý��ջ���Ĵ�С�����������Ͽ�����
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
		callback = cb,	-- �յ���Ϣ�Ļص�
	}
end

-- ����һ�� udp handle
-- callback �ص������������ handle �յ� udp ��Ϣʱ��callback ������������
-- host �󶨵� ip��Ĭ��Ϊ ipv4 �� 0.0.0.0 
-- port �󶨵� port��Ĭ��Ϊ 0�����ʾ������һ�� udp handle �����ڷ��ͣ��������󶨹̶��˿�
function socket.udp(callback, host, port)
	local id = driver.udp(host, port)	-- �������ӣ������ǰ󶨱��ض˿������շ����ݣ�����Ҳ����suspend
	create_udp_object(id, callback)
	return id
end

-- ��һ�� udp handle ����һ��Ĭ�ϵķ���Ŀ�ĵ�ַ
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

-- ��һ�������ַ����һ�����ݰ� id, from, data
-- �ڶ������� from ����һ�������ַ������һ�� string ��ͨ���� callback �������ɣ����޷��Լ�����һ����ַ����������԰� callback �����еõ��ĵ�ַ�����������Ժ�ʹ�á����͵�������һ���ַ��� data ��
socket.sendto = assert(driver.udp_send)
-- ����ַ��������� socket.udp_address(from) : address port ת��Ϊ�ɶ��� ip ��ַ�Ͷ˿ڣ����ڼ�¼��
socket.udp_address = assert(driver.udp_address)

function socket.warning(id, callback)
	local obj = socket_pool[id]
	assert(obj)
	obj.on_warning = callback
end

return socket
