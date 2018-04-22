-- ���з�����������״̬����
local c = require "skynet.core"
local tostring = tostring
local tonumber = tonumber
local coroutine = coroutine
local assert = assert
local pairs = pairs
local pcall = pcall
local table = table

local profile = require "skynet.profile"

local coroutine_resume = profile.resume
local coroutine_yield = profile.yield

local proto = {}
local skynet = {
	-- read skynet.h
	PTYPE_TEXT = 0,
	PTYPE_RESPONSE = 1,
	PTYPE_MULTICAST = 2,
	PTYPE_CLIENT = 3,
	PTYPE_SYSTEM = 4,
	PTYPE_HARBOR = 5,
	PTYPE_SOCKET = 6,
	PTYPE_ERROR = 7,
	PTYPE_QUEUE = 8,	-- used in deprecated mqueue, use skynet.queue instead
	PTYPE_DEBUG = 9,
	PTYPE_LUA = 10,
	PTYPE_SNAX = 11,
}

-- code cache
skynet.cache = require "skynet.codecache"

-- class.dispatch�Ĳ���Ϊsession, source, p.unpack(msg, sz, ...)
function skynet.register_protocol(class)
	local name = class.name
	local id = class.id
	assert(proto[name] == nil and proto[id] == nil)
	assert(type(name) == "string" and type(id) == "number" and id >=0 and id <=255)
	proto[name] = class
	proto[id] = class
end

local session_id_coroutine = {}			-- [session] = co���ȴ��Է�(session)��Ӧ���б�co�Ƿ���������֮��yield��Э�̣���Ϊ�ȴ���Ӧ��ͨ��sesion����ʶ������sessionΪkey
local session_coroutine_id = {}			-- [co] = session���յ��������б�for session��co:���������Э�̣�session:����id
local session_coroutine_address = {}
local session_response = {}
local unresponse = {}

local wakeup_queue = {}
local sleep_session = {}

local watching_service = {}
local watching_session = {}
local dead_service = {}
local error_queue = {}					-- �����session�б�
local fork_queue = {}					-- ��ִ�е�fork����

-- suspend is function
local suspend

-- ʮ�����Ƶ�ַ(:00000000)תnumber
local function string_to_handle(str)
	return tonumber("0x" .. string.sub(str , 2))
end

----- monitor exit
-- ĳЩ���󲻱ؼ����ȴ�����Ϊ�Է��Ĵ���˻Ự�Ѿ�ʧЧ���������ȴ�
-- ÿ��ȡһ��
local function dispatch_error_queue()
	local session = table.remove(error_queue,1)
	if session then
		local co = session_id_coroutine[session]
		session_id_coroutine[session] = nil
		return suspend(co, coroutine_resume(co, false))
	end
end

-- �յ��Է������Ĵ��󱨸�
-- error_source��ָ��ķ����ڴ���error_session ����Ự��ʱ�����״��
local function _error_dispatch(error_session, error_source)
	if error_session == 0 then
		-- �����������״��������ĳ���Ự
		-- service is down
		--  Don't remove from watching_service , because user may call dead service
		if watching_service[error_source] then
			dead_service[error_source] = true
		end
		-- ��һ����������û���ڵȴ�error_source��Ӧ
		for session, srv in pairs(watching_session) do
			if srv == error_source then
				table.insert(error_queue, session) -- ������ڵȴ�error_source��ָ���ķ��񷵻أ���ô���Բ��õ��ˣ�����error_source�����������ʽ�ĵ�ַ
			end
		end
	else
		-- capture an error for error_session
		if watching_session[error_session] then
			table.insert(error_queue, error_session)
		end
	end
end

-- coroutine reuse http://blog.codingnow.com/2013/07/coroutine_reuse.html

local coroutine_pool = setmetatable({}, { __mode = "kv" })

local function co_create(f)
	local co = table.remove(coroutine_pool)
	if co == nil then
		co = coroutine.create(function(...)
			f(...)
			while true do
				f = nil	-- for gc
				coroutine_pool[#coroutine_pool+1] = co	-- �ŵ�Э�̳��й�֮����
				f = coroutine_yield "EXIT" -- ����Э�̣����Ժ��á���Э���յ�EXIT���������ݣ����õ�ʱ��create�����¥�µ�resume(co, f)��ʱ��yield�������أ�����ֵ����resume�����f
				f(coroutine_yield())	   -- ��������ʱ��������������ִ�У����ٴε���resume��ʱ���ִ��,��Ϊ����coroutine.create������
			end
		end)
	else
		coroutine_resume(co, f)
	end
	return co
end

local function dispatch_wakeup()
	local co = table.remove(wakeup_queue,1)
	if co then
		local session = sleep_session[co]
		if session then
			session_id_coroutine[session] = "BREAK"			-- ���sleep������ִ��
			return suspend(co, coroutine_resume(co, false, "BREAK"))
		end
	end
end

-- ȡ����address�Ĺ�ע
local function release_watching(address)
	local ref = watching_service[address]
	if ref then
		ref = ref - 1
		if ref > 0 then
			watching_service[address] = ref
		else
			watching_service[address] = nil
		end
	end
end

-- suspend is local function
-- ������
-- Э�̵���yield���resume���صĺ�������
-- resume ���صĶ���ret, command, ....(ͨ��yield���أ���ʹ�˳�Ҳ���ߵ�co_create�����EXIT����)
-- �κ�co�Ĺ���(resume�ķ���)�������ߵ�suspend�������ڹ����ʱ��resume��co
function suspend(co, result, command, param, size)
	-- Э��ִ�й����г�������������
	if not result then
		local session = session_coroutine_id[co]
		if session then -- coroutine may fork by others (session is nil)
			local addr = session_coroutine_address[co]
			if session ~= 0 then
				-- only call response error
				c.send(addr, skynet.PTYPE_ERROR, session, "")
			end
			session_coroutine_id[co] = nil
			session_coroutine_address[co] = nil
		end
		error(debug.traceback(co,tostring(command))) -- command �Ǵ�����Ϣ
	end
	-- command ��ʾ��������ԭ��
	if command == "CALL" then
		session_id_coroutine[param] = co	-- ��Ϊcall�Է����Թ���ȴ���Ӧ
	elseif command == "SLEEP" then
		session_id_coroutine[param] = co	-- ��Ϊsleep���Թ���ȴ�timeout
		sleep_session[co] = param
	elseif command == "RETURN" then			-- ��Ӧactor����
		local co_session = session_coroutine_id[co]
		if co_session == 0 then
			if size ~= nil then
				c.trash(param, size)
			end
			return suspend(co, coroutine_resume(co, false))	-- send don't need ret
		end
		local co_address = session_coroutine_address[co]
		if param == nil or session_response[co] then
			error(debug.traceback(co))
		end
		session_response[co] = true
		local ret
		if not dead_service[co_address] then
			ret = c.send(co_address, skynet.PTYPE_RESPONSE, co_session, param, size) ~= nil
			if not ret then
				-- If the package is too large, returns nil. so we should report error back
				c.send(co_address, skynet.PTYPE_ERROR, co_session, "")
			end
		elseif size ~= nil then
			c.trash(param, size)
			ret = false
		end
		return suspend(co, coroutine_resume(co, ret)) -- send �Ľ�����ص���skynet.ret�ĵط�
	elseif command == "RESPONSE" then
		local co_session = session_coroutine_id[co]
		local co_address = session_coroutine_address[co]
		if session_response[co] then
			error(debug.traceback(co))
		end
		local f = param -- pack����
		local function response(ok, ...)
			if ok == "TEST" then
				if dead_service[co_address] then
					release_watching(co_address)
					unresponse[response] = nil
					f = false
					return false
				else
					return true
				end
			end
			if not f then
				if f == false then
					f = nil
					return false
				end
				error "Can't response more than once"
			end

			local ret
			-- do not response when session == 0 (send)
			if co_session ~= 0 and not dead_service[co_address] then
				if ok then
					ret = c.send(co_address, skynet.PTYPE_RESPONSE, co_session, f(...)) ~= nil
					if not ret then
						-- If the package is too large, returns false. so we should report error back
						c.send(co_address, skynet.PTYPE_ERROR, co_session, "")
					end
				else
					ret = c.send(co_address, skynet.PTYPE_ERROR, co_session, "") ~= nil
				end
			else
				ret = false
			end
			release_watching(co_address)
			unresponse[response] = nil
			f = nil
			return ret
		end
		watching_service[co_address] = watching_service[co_address] + 1
		session_response[co] = true
		unresponse[response] = true
		return suspend(co, coroutine_resume(co, response))
	elseif command == "EXIT" then
		-- coroutine exit
		-- ���������Э���˳�
		local address = session_coroutine_address[co]
		if address then
			release_watching(address)
			session_coroutine_id[co] = nil
			session_coroutine_address[co] = nil
			session_response[co] = nil
		end
	elseif command == "QUIT" then
		-- service exit
		return
	elseif command == "USER" then
		-- See skynet.coutine for detail
		error("Call skynet.coroutine.yield out of skynet.coroutine.resume\n" .. debug.traceback(co))
	elseif command == nil then
		-- debug trace
		return
	else
		error("Unknown command : " .. command .. "\n" .. debug.traceback(co))
	end
	dispatch_wakeup()		-- ������ĳ��Э�̹���֮�󣬿��Ի�������Э��
	dispatch_error_queue()	-- �ȴ���ĳЩsession��Ϊ�Է�ԭ������������
end

-- ����������
function skynet.timeout(ti, func)
	local session = c.intcommand("TIMEOUT",ti)
	assert(session)
	local co = co_create(func)
	assert(session_id_coroutine[session] == nil)
	session_id_coroutine[session] = co	-- �ȴ�timeout��Ӧ
end

-- ��������
function skynet.sleep(ti)
	local session = c.intcommand("TIMEOUT",ti)
	assert(session)
	local succ, ret = coroutine_yield("SLEEP", session)
	sleep_session[coroutine.running()] = nil
	if succ then
		return
	end
	if ret == "BREAK" then
		return "BREAK"
	else
		error(ret)
	end
end

function skynet.yield()
	return skynet.sleep(0)
end

function skynet.wait(co)
	local session = c.genid()
	local ret, msg = coroutine_yield("SLEEP", session)
	co = co or coroutine.running()
	sleep_session[co] = nil
	session_id_coroutine[session] = nil
end


-- ��÷����Լ��ĵ�ַ
function skynet.self()
	return c.addresscommand "REG"
end

-- ����һ���ֲ�����".xxxxxx"���Ҷ�Ӧ��handle
function skynet.localname(name)
	return c.addresscommand("QUERY", name)
end

skynet.now = c.now

local starttime

function skynet.starttime()
	if not starttime then
		starttime = c.intcommand("STARTTIME")
	end
	return starttime
end

function skynet.time()
	return skynet.now()/100 + (starttime or skynet.starttime())
end

function skynet.exit()
	fork_queue = {}	-- no fork coroutine can be execute after skynet.exit
	skynet.send(".launcher","lua","REMOVE",skynet.self(), false)
	-- report the sources that call me
	for co, session in pairs(session_coroutine_id) do	-- �ȴ��������Ӧ��Э�̶��˳�
		local address = session_coroutine_address[co]	-- �Է���ַ
		if session~=0 and address then
			c.send(address, skynet.PTYPE_ERROR, session, "")
		end
	end
	for resp in pairs(unresponse) do
		resp(false)
	end
	-- report the sources I call but haven't return
	local tmp = {}
	for session, address in pairs(watching_session) do
		tmp[address] = true
	end
	for address in pairs(tmp) do
		c.send(address, skynet.PTYPE_ERROR, 0, "")
	end
	c.command("EXIT")
	-- quit service
	coroutine_yield "QUIT"
end

-- ���ص�ǰ������ע������ֵ
function skynet.getenv(key)
	return (c.command("GETENV",key))
end

-- ��ǰ������ע������һ��(���������������������
function skynet.setenv(key, value)
	assert(c.command("GETENV",key) == nil, "Can't setenv exist key : " .. key)
	c.command("SETENV",key .. " " ..value)
end

-- ���� API ���԰�һ�����Ϊ typename ����Ϣ���͸� address �������Ⱦ�������ע���
--  pack ������� ... �����ݡ�
-- skynet.send ��һ�������� API ����������Ϣ��coroutine ������������У����ڼ��
-- �񲻻����롣
-- ĳЩ����û��pack����?ֻ��lua������
function skynet.send(addr, typename, ...)
	local p = proto[typename]
	return c.send(addr, p.id, 0 , p.pack(...))
end

function skynet.rawsend(addr, typename, msg, sz)
	local p = proto[typename]
	return c.send(addr, p.id, 0 , msg, sz)
end

skynet.genid = assert(c.genid)

-- �ض���α��source��dest������Ϣ
skynet.redirect = function(dest,source,typename,...)
	return c.redirect(dest, source, proto[typename].id, ...)
end

-- pack ��Ҫ���ڷ��ͣ���Ҫ֪���Է������unpack����ȷ���Լ����pack
-- ����һ��������˵����Ҫ��עunpack��������Լ������ʽ��������Ҫ������
skynet.pack = assert(c.pack)
skynet.packstring = assert(c.packstring)
skynet.unpack = assert(c.unpack)
skynet.tostring = assert(c.tostring)
skynet.trash = assert(c.trash)

-- ����ȴ�CALL����ķ��أ�����֮ǰһ����CALL�����ͳ�ȥ
local function yield_call(service, session)
	watching_session[session] = service
	local succ, msg, sz = coroutine_yield("CALL", session)
	watching_session[session] = nil
	if not succ then
		error "call failed"
	end
	return msg,sz
end

-- �������ڲ�����һ��Ψһ session ������ address �������󣬲�������
-- ���� session �Ļ�Ӧ�����Բ��� address ��Ӧ��������Ϣ��Ӧ�󣬻���
-- ͨ��֮ǰע��� unpack ��������������Ͽ����������Ƿ�����һ�� RPC��
-- �������ȴ���Ӧ��
-- skynet.call ��������ס��ǰ�� coroutine ����û���������������ڵȴ�
-- ��Ӧ�ڼ䣬��������������Ӧ�����������ԣ�����Ҫע�⣬�� skynet.call
--  ֮ǰ��õķ����ڵ�״̬�������غ󣬺��п��ܸı�

-- ���ܻ��׳��쳣������������Ҫpcall
function skynet.call(addr, typename, ...)
	local p = proto[typename]
	local session = c.send(addr, p.id , nil , p.pack(...))
	if session == nil then
		error("call to invalid address " .. skynet.address(addr))
	end
	return p.unpack(yield_call(addr, session))
end

-- ������������һ�����󣬲��ȴ���Ӧ�����ݺͷ���ֵû��pack��unpack
-- ֻ����һ��Э���з���
-- ����ֵΪyield_call
function skynet.rawcall(addr, typename, msg, sz)
	local p = proto[typename]
	local session = assert(c.send(addr, p.id , nil , msg, sz), "call to invalid address")
	return yield_call(addr, session)
end

-- ����lua�����յ���ķ������������ʱ��ᴴ��һ��coȥִ����Ӧ������(raw_dispatch_message)
-- ��ִ��co�Ĺ����У����Ե���skynet.ret�ѽ�����ظ�Դ����
-- ������ API
function skynet.ret(msg, sz)
	msg = msg or ""
	return coroutine_yield("RETURN", msg, sz)
end

--[[
	�յ����󻹲����������أ�����ͨ���˺�������һ���հ����հ����õ�ʱ�����������
	���շ����ã�����һ���հ����Ժ��������հ����ɰѻ�Ӧ��Ϣ���ء�����Ĳ��� skynet.pack �ǿ�ѡ�ģ�����Դ���
	�������������Ĭ�ϼ��� skynet.pack ��

	skynet.response ���صıհ��������ӳٻ�Ӧ��������ʱ����һ������ͨ���� true ��ʾ��һ�������Ļ�Ӧ
	��֮��Ĳ�������Ҫ��Ӧ�����ݡ������ false ������������׳�һ���쳣�����ķ���ֵ��ʾ��Ӧ�ĵ�ַ��
	����Ч������������֪����Ӧ��ַ����Ч�ԣ���ô�����ڵ�һ���������� "TEST" ���ڼ�⡣
]]
-- ������ API
function skynet.response(pack)
	pack = pack or skynet.pack
	return coroutine_yield("RESPONSE", pack)
end

-- ���һϵ�в���Ȼ�󷵻ظ��Է�
function skynet.retpack(...)
	return skynet.ret(skynet.pack(...))
end

-- ���ĳsleep��wait��Э�̿��Ա�����
function skynet.wakeup(co)
	if sleep_session[co] then
		table.insert(wakeup_queue, co)
		return true
	end
end

-- ����proto[typename]��dispatch����
function skynet.dispatch(typename, func)
	local p = proto[typename]
	if func then
		local ret = p.dispatch
		p.dispatch = func
		return ret
	else
		return p and p.dispatch
	end
end

local function unknown_request(session, address, msg, sz, prototype)
	skynet.error(string.format("Unknown request (%s): %s", prototype, c.tostring(msg,sz)))
	error(string.format("Unknown session : %d from %x", session, address))
end

-- Ϊ�޷��������Ϣ�����趨һ��������
function skynet.dispatch_unknown_request(unknown)
	local prev = unknown_request
	unknown_request = unknown
	return prev
end

-- Ϊ�޷�����Ļ�Ӧ��Ϣ�趨һ��������
local function unknown_response(session, address, msg, sz)
	skynet.error(string.format("Response message : %s" , c.tostring(msg,sz)))
	error(string.format("Unknown session : %d from %x", session, address))
end

function skynet.dispatch_unknown_response(unknown)
	local prev = unknown_response
	unknown_response = unknown
	return prev
end

function skynet.fork(func,...)
	local args = table.pack(...)
	local co = co_create(function()
		func(table.unpack(args,1,args.n))
	end)
	table.insert(fork_queue, co)
	return co
end

-- ����һ����Ϣ
local function raw_dispatch_message(prototype, msg, sz, session, source)
	-- skynet.PTYPE_RESPONSE = 1, read skynet.h
	if prototype == 1 then
		-- �յ�actor��Ӧ
		local co = session_id_coroutine[session]
		if co == "BREAK" then
			session_id_coroutine[session] = nil
		elseif co == nil then						-- �ȴ���Ӧ��Э��û�ˣ�
			unknown_response(session, source, msg, sz)
		else
			session_id_coroutine[session] = nil
			-- Ϊɶ���ﲻ��p.unpack(msg, sz)����Ϊ�ò��������type
			-- ����resume��Э����Ҫ�Լ�unpack
			suspend(co, coroutine_resume(co, true, msg, sz))	-- ��Ӧ���ˣ�����ִ��Э��
		end
	else
		-- �յ�actor����
		local p = proto[prototype]	-- �����Ƿ�������Э�飬�õ���Ӧ��ע����Ϣ
		if p == nil then
			if session ~= 0 then
				c.send(source, skynet.PTYPE_ERROR, session, "")
			else
				unknown_request(session, source, msg, sz, prototype)
			end
			return
		end
		local f = p.dispatch	-- dispatch��������p.unpack֮�������
		if f then
			-- ˭�������ע˭
			local ref = watching_service[source]
			if ref then
				watching_service[source] = ref + 1
			else
				watching_service[source] = 1
			end
			-- ͨ���¿�һ��Э������������
			local co = co_create(f)
			session_coroutine_id[co] = session
			session_coroutine_address[co] = source
			suspend(co, coroutine_resume(co, session,source, p.unpack(msg,sz)))
		elseif session ~= 0 then
			c.send(source, skynet.PTYPE_ERROR, session, "")
		else
			unknown_request(session, source, msg, sz, proto[prototype].name)	-- û�д�����
		end
	end
end

-- ����һ����Ϣ�����з�����snlua�������Ϣ�����������������type��ʲô����
-- ...Ϊtype, msg, sz, session, source
function skynet.dispatch_message(...)
	local succ, err = pcall(raw_dispatch_message,...)
	-- ������һ����Ϣ�󣬲鿴������Ϣ��������Щ��ִ��fork����һִ��
	while true do
		local key,co = next(fork_queue)
		if co == nil then
			break
		end
		fork_queue[key] = nil
		local fork_succ, fork_err = pcall(suspend,co,coroutine_resume(co))
		if not fork_succ then
			if succ then
				succ = false
				err = tostring(fork_err)
			else
				err = tostring(err) .. "\n" .. tostring(fork_err)	-- �����������
			end
		end
	end
	assert(succ, tostring(err))
end

--[[
[DESC]
	����һ����Ϊ name �� Lua ����name Ҳ�Ƿ���ű������֣�����д .lua ��׺����
ֻ�б������Ľű��� start �������غ���� API �Ż᷵�������ķ���ĵ�ַ������һ������ API ��

A����ͨ��launcher��������B����launcher����������B�󱣴�һ���ӳ�ȷ�ϵıհ�response��B��
���ɹ���֪ͨlauncher����LAUNCHOK�ˡ�launcher�Ӷ�ִ��֮ǰ���ӳ�ȷ�ϱհ���֪ͨA������������
����������ĺô���launcher���õ�B������ɣ�����ȥ�������

ע�⣺����������ʵ�����ַ���ƴ�ӵķ�ʽ���ݹ�ȥ�ġ����Բ�Ҫ�ڲ����д��ݸ��ӵ� Lua ���󡣽��յ�
�Ĳ��������ַ��������ַ����в������пո񣨷���ᱻ�ָ�ɶ�������������ֲ������ݷ�ʽ����ʷ����
�����ģ��кܶ�Ǳ�ڵ����⡣Ŀǰ�Ƽ��Ĺ����ǣ�����ķ�����Ӧһ��������Ϣ���� newservice ֮����
�̵��� skynet.call ������������

[RETURN]
	handle

[ERROR]
	���ܻ����쳣������Ҫ�� pcall ������

[BLOCK]
	YES
]]
function skynet.newservice(name, ...)
	return skynet.call(".launcher", "lua" , "LAUNCH", "snlua", name, ...)
end

-- https://github.com/cloudwu/skynet/wiki/UniqueService

-- ����һ��ȫ�ַ���
-- global Ϊtrue��ʱ���ʾ����������Ψһ������globalΪservice name����ʾ�ڱ����Ψһ
function skynet.uniqueservice(global, ...)
	if global == true then
		return assert(skynet.call(".service", "lua", "GLAUNCH", ...))
	else
		return assert(skynet.call(".service", "lua", "LAUNCH", global, ...))
	end
end

-- ��ѯһ��ȫ�ַ��񣬲�����skynet.uniqueserviceһ��
-- global Ϊtrue��ʱ���ʾ����������Ψһ������globalΪservice name����ʾ�ڱ����Ψһ
-- skynet.queryservice ����ѯ���з������������񲻴��ڣ���� api ��һֱ��������������Ϊֹ
function skynet.queryservice(global, ...)
	if global == true then
		return assert(skynet.call(".service", "lua", "GQUERY", ...))
	else
		return assert(skynet.call(".service", "lua", "QUERY", global, ...))
	end
end

-- ���ڰ�һ����ַ����ת��Ϊһ���������Ķ����ַ���
function skynet.address(addr)
	if type(addr) == "number" then
		return string.format(":%08x",addr)
	else
		return tostring(addr)
	end
end

function skynet.harbor(addr)
	return c.harbor(addr)
end

-- ��logger������һ����Ϣ
skynet.error = c.error

----- register protocol
-- ���¸���Э������������lua���񶼻��е�
do
	local REG = skynet.register_protocol

	-- lua��dispatch�ɸ���������
	REG {
		name = "lua",
		id = skynet.PTYPE_LUA,
		pack = skynet.pack,
		unpack = skynet.unpack,
	}

	-- ĳ���������Ӧsource���񣬿���ͨ��skynet.send "response" ���͵���Ϣ�����Ǹ��򵥵ķ�������ret
	REG {
		name = "response",
		id = skynet.PTYPE_RESPONSE,
	}

	-- ���������Ϣ
	REG {
		name = "error",
		id = skynet.PTYPE_ERROR,
		unpack = function(...) return ... end,
		dispatch = _error_dispatch,
	}
end

local init_func = {}

-- init ע��ĺ�����������������ִ��
-- ��������lua lib��ʱ��������ô�lib��Ҫ����һЩ��ʼ��������ʱ�򣬿��Խ�����
-- ��ע�ᣬ��Щ���������������ģ���Ϊskynet.start���Ὺһ��timeout���߳�����ִ
-- ��(������ȷ�Ĺ���)
function skynet.init(f, name)
	assert(type(f) == "function")
	if init_func == nil then	-- �Ѿ����˳�ʼ������
		f()
	else
		table.insert(init_func, f)
		if name then
			assert(type(name) == "string")
			assert(init_func[name] == nil)
			init_func[name] = f
		end
	end
end

local function init_all()
	local funcs = init_func
	init_func = nil
	if funcs then
		for _,f in ipairs(funcs) do
			f()
		end
	end
end

local function ret(f, ...)
	f()								-- ����start����ע��ĳ�ʼ������
	return ...						-- ����start()�Ľ��
end

local function init_template(start, ...)
	init_all()						-- ���ó�ʼ������
	init_func = {}
	return ret(init_all, start(...))
end

function skynet.pcall(start, ...)
	return xpcall(init_template, debug.traceback, start, ...)
end

function skynet.init_service(start)
	local ok, err = skynet.pcall(start)
	if not ok then
		skynet.error("init service failed: " .. tostring(err))
		skynet.send(".launcher","lua", "ERROR")
		skynet.exit()
	else
		skynet.send(".launcher","lua", "LAUNCHOK")	-- A����ͨ��launcher��������B����launcher����������B�󱣴�һ���ӳ�ȷ�ϵıհ�response��Bִ�е�����˵���ɹ������ˣ�֪ͨlauncher����LAUNCHOK�ˡ�launcher�Ӷ�ִ��֮ǰ���ӳ�ȷ�ϱհ���֪ͨA�����������Ľ��
	end
end

-- ע��һ����������
function skynet.start(start_func)
	c.callback(skynet.dispatch_message)	-- ������Ϣ�ַ�����
	-- ͨ���ڼ��ط���Դ�ļ���ʱ����ô˺���������׶β����Ե����κ��п�
	-- ������ס�÷���� skynet api ����Ϊ��������׶��У��ͷ������׵� 
	-- skynet ���ò�û�г�ʼ����ϡ�
	skynet.timeout(0, function()
		skynet.init_service(start_func)
	end)
end

-- �鿴�������Ƿ��ڴ���ĳ����Ϣ��ʱ����ʱ��ʱ��core������һ��״̬
function skynet.endless()
	return (c.intcommand("STAT", "endless") == 1)
end

-- �����Ϣ���еĳ���
function skynet.mqlen()
	return c.intcommand("STAT", "mqlen")
end

function skynet.stat(what)
	return c.intcommand("STAT", what)
end

function skynet.task(ret)
	local t = 0
	for session,co in pairs(session_id_coroutine) do
		if ret then
			ret[session] = debug.traceback(co)
		end
		t = t + 1
	end
	return t
end

-- ָ��ĳ�������Ѿ�ʧЧ
function skynet.term(service)
	return _error_dispatch(0, service)
end

-- �趨��ǰ����������ʹ�ö����ֽڵ��ڴ棬�ú����������� start �������á�
function skynet.memlimit(bytes)
	debug.getregistry().memlimit = bytes
	skynet.memlimit = nil	-- set only once
end

-- Inject internal debug framework
local debug = require "skynet.debug"
debug.init(skynet, {
	dispatch = skynet.dispatch_message,
	suspend = suspend,
})

return skynet
