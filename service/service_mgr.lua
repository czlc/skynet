local skynet = require "skynet"
require "skynet.manager"	-- import skynet.register
local snax = require "skynet.snax"

local cmd = {}
local service = {}	-- ����֮ǰ��[service_name] = {launch = true, co1, co2, ...}���ȴ���ѯ��������Э���б�
					-- ����֮��[service_name] = handle���ڵ�洢������ȫ�ַ���

-- ����ĳ������func�����������ĺ���
local function request(name, func, ...)
	local ok, handle = pcall(func, ...)
	local s = service[name]
	assert(type(s) == "table")
	if ok then
		service[name] = handle
	else
		service[name] = tostring(handle)	-- ����ʧ��service[name] ������ַ���
	end

	-- ͬʱ���������Э�̶����Խ�ɢ��
	for _,v in ipairs(s) do
		skynet.wakeup(v)
	end

	if ok then
		return handle
	else
		error(tostring(handle))
	end
end

-- ����һ��service��������Э��ͬʱ�������˴���
-- name���ڲ��ң�func����new service, arg[1]��service name
local function waitfor(name , func, ...)
	local s = service[name]
	if type(s) == "number" then
		return s
	end
	local co = coroutine.running()	-- ��ǰ��Э�̣���Ϊ����������ͨ����һ���µ�Э��

	if s == nil then
		s = {}	-- s�Ǻ󵽵����봴���˷����Э�̵�Э���б���ΪҪ��֤Э����node��Ψһ������ֻ�еȴ����ȴ������˾ͻỽ������
		service[name] = s
	elseif type(s) == "string" then
		error(s)
	end

	assert(type(s) == "table")

	if not s.launch and func then
		s.launch = true	-- ����Ϊ����������ͬʱֻ����һ��Э��ȥ����
		return request(name, func, ...)
	end

	-- �Ѿ�����ȥ�����ˣ����ǻ�û�еȵ���������Եȱ�����֪ͨ
	table.insert(s, co)
	skynet.wait()
	s = service[name]
	if type(s) == "string" then
		error(s)
	end
	assert(type(s) == "number")
	return s
end

local function read_name(service_name)
	if string.byte(service_name) == 64 then -- '@'
		return string.sub(service_name , 2)
	else
		return service_name
	end
end

-- service_name = "snaxd", subname = "pingserver"
-- ��֤����service_name�ڽڵ���Ψһ
function cmd.LAUNCH(service_name, subname, ...)
	local realname = read_name(service_name)

	if realname == "snaxd" then
		return waitfor(service_name.."."..subname, snax.rawnewservice, subname, ...)
	else
		return waitfor(service_name, skynet.newservice, realname, subname, ...)
	end
end

function cmd.QUERY(service_name, subname)
	local realname = read_name(service_name)

	if realname == "snaxd" then
		return waitfor(service_name.."."..subname)
	else
		return waitfor(service_name)
	end
end

-- ��ñ�����ȫ�ַ����б�
local function list_service()
	local result = {}
	for k,v in pairs(service) do
		if type(v) == "string" then
			v = "Error: " .. v
		elseif type(v) == "table" then
			v = "Querying"
		else
			v = skynet.address(v)
		end

		result[k] = v
	end

	return result
end


local function register_global()
	function cmd.GLAUNCH(name, ...)
		-- ����master��˵������ע�ᵽ���ؾͿ�����
		local global_name = "@" .. name
		return cmd.LAUNCH(global_name, ...)
	end

	function cmd.GQUERY(name, ...)
		local global_name = "@" .. name
		return cmd.QUERY(global_name, ...)
	end

	local mgr = {}

	-- slave service_mgr ע���Լ�, m����handle
	function cmd.REPORT(m)
		mgr[m] = true
	end

	local function add_list(all, m)
		local harbor = "@" .. skynet.harbor(m)
		local result = skynet.call(m, "lua", "LIST")
		for k,v in pairs(result) do
			all[k .. harbor] = v
		end
	end

	-- ������нڵ��ȫ�ַ����б�
	function cmd.LIST()
		local result = {}
		for k in pairs(mgr) do
			pcall(add_list, result, k)
		end
		local l = list_service()
		for k, v in pairs(l) do
			result[k] = v
		end
		return result
	end
end

local function register_local()
	local function waitfor_remote(cmd, name, ...)
		local global_name = "@" .. name
		local local_name
		if name == "snaxd" then
			local_name = global_name .. "." .. (...)
		else
			local_name = global_name
		end
		return waitfor(local_name, skynet.call, "SERVICE", "lua", cmd, global_name, ...)
	end

	-- ����һ��ȫ��Ψһ�ķ���
	function cmd.GLAUNCH(...)
		return waitfor_remote("LAUNCH", ...)
	end
	-- ��ѯһ��ȫ��Ψһ�ķ���
	function cmd.GQUERY(...)
		return waitfor_remote("QUERY", ...)
	end

	function cmd.LIST()
		return list_service()
	end

	skynet.call("SERVICE", "lua", "REPORT", skynet.self())
end

skynet.start(function()
	skynet.dispatch("lua", function(session, address, command, ...)
		local f = cmd[command]
		if f == nil then
			skynet.ret(skynet.pack(nil, "Invalid command " .. command))
			return
		end

		local ok, r = pcall(f, ...)

		if ok then
			skynet.ret(skynet.pack(r))
		else
			skynet.ret(skynet.pack(nil, r))
		end
	end)
	local handle = skynet.localname ".service"
	if  handle then
		skynet.error(".service is already register by ", skynet.address(handle))
		skynet.exit()
	else
		skynet.register(".service")
	end
	if skynet.getenv "standalone" then	-- master ���
		skynet.register("SERVICE")		-- master ������SERVICE��������
		register_global()
	else
		register_local()
	end
end)
