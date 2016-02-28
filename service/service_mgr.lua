local skynet = require "skynet"
require "skynet.manager"	-- import skynet.register
local snax = require "snax"

local cmd = {}
local service = {}

-- name = "snaxd.pingserver", func = snax.rawnewservice, "pingserver", "hello world"
-- name用于查找，func用作new service, arg[1]是service name
local function request(name, func, ...)
	local ok, handle = pcall(func, ...)
	local s = service[name]
	assert(type(s) == "table")
	if ok then
		service[name] = handle
	else
		service[name] = tostring(handle)	-- 调用失败service[name] 存错误字符串
	end

	for _,v in ipairs(s) do
		skynet.wakeup(v)
	end

	if ok then
		return handle
	else
		error(tostring(handle))
	end
end

-- 启动一个service，避免多个协程同时请求做了处理
-- name用于查找，func用作new service, arg[1]是service name
local function waitfor(name , func, ...)
	local s = service[name]
	if type(s) == "number" then
		return s
	end
	local co = coroutine.running()	-- 当前的协程，因为处理请求都是通过开一个新的协程

	if s == nil then
		s = {}	-- s是后到的申请创建此服务的协程的协程列表，因为要保证协程在node中唯一，所以只有等待，等创建好了就会唤醒他们
		service[name] = s
	elseif type(s) == "string" then
		error(s)
	end

	assert(type(s) == "table")

	if not s.launch and func then
		s.launch = true
		return request(name, func, ...)
	end

	-- 已经有人去请求了，但是还没有等到结果，所以等别人来通知
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
-- 保证服务service_name在节点内唯一
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
		local global_name = "@" .. name
		return cmd.LAUNCH(global_name, ...)
	end

	function cmd.GQUERY(name, ...)
		local global_name = "@" .. name
		return cmd.QUERY(global_name, ...)
	end

	local mgr = {}

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
	function cmd.GLAUNCH(name, ...)
		local global_name = "@" .. name
		return waitfor(global_name, skynet.call, "SERVICE", "lua", "LAUNCH", global_name, ...)
	end

	function cmd.GQUERY(name, ...)
		local global_name = "@" .. name
		return waitfor(global_name, skynet.call, "SERVICE", "lua", "QUERY", global_name, ...)
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
	if skynet.getenv "standalone" then	-- master 结点
		skynet.register("SERVICE")	-- master 结点才有SERVICE命名服务
		register_global()
	else
		register_local()
	end
end)
