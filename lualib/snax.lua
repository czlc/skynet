local skynet = require "skynet"
local snax_interface = require "snax.interface"

local snax = {}
local typeclass = {}

local interface_g = skynet.getenv("snax_interface_g")
local G = interface_g and require (interface_g) or { require = function() end }
interface_g = nil

skynet.register_protocol {
	name = "snax",
	id = skynet.PTYPE_SNAX,
	pack = skynet.pack,
	unpack = skynet.unpack,
}

-- "pingserver"
-- 获得一个snax service的接口，它包括accept、response、system接口
function snax.interface(name)
	if typeclass[name] then
		return typeclass[name]
	end

	local si = snax_interface(name, G)

	local ret = {
		name = name,
		accept = {},	-- accept 前缀表示这个方法没有回应
		response = {},  -- response 前缀表示这个方法一定有一个回应
		system = {},	-- 一些全局函数，比如init、exit
	}

	-- 按accept, response,system分类
	for _,v in ipairs(si) do
		local id, group, name, f = table.unpack(v)
		ret[group][name] = id -- 便于查找id，用的时候根据id可以找到f
	end

	typeclass[name] = ret
	return ret
end

local meta = { __tostring = function(v) return string.format("[%s:%x]", v.type, v.handle) end}

local skynet_send = skynet.send
local skynet_call = skynet.call

-- service.post.__index的时候返回指定函数，调用无需等待结果
local function gen_post(type, handle)
	return setmetatable({} , {
		__index = function( t, k )
			local id = type.accept[k]
			if not id then
				error(string.format("post %s:%s no exist", type.name, k))
			end
			return function(...)
				skynet_send(handle, "snax", id, ...)
			end
		end })
end

-- service.req.__index的时候返回指定函数，调用需要等待结果
local function gen_req(type, handle)
	return setmetatable({} , {
		__index = function( t, k )
			local id = type.response[k]
			if not id then
				error(string.format("request %s:%s no exist", type.name, k))
			end
			return function(...)
				return skynet_call(handle, "snax", id, ...)
			end
		end })
end

-- type是按[group][name]->id的查询table
local function wrapper(handle, name, type)
	return setmetatable ({
		post = gen_post(type, handle),	-- 使得post.xxx函数调用 是发送消息到snaxd
		req = gen_req(type, handle),	-- 使得req.xxx函数调用 是发消息到snaxd
		type = name,
		handle = handle,
		}, meta)
end

local handle_cache = setmetatable( {} , { __mode = "kv" } ) -- cache 所有的snaxd服务

function snax.rawnewservice(name, ...)
	local t = snax.interface(name)
	local handle = skynet.newservice("snaxd", name) -- 启动一个snaxd服务
	assert(handle_cache[handle] == nil)
	if t.system.init then
		skynet.call(handle, "snax", t.system.init, ...)
	end
	return handle
end

-- 绑定snaxd service的handle和相关service name
function snax.bind(handle, type)
	local ret = handle_cache[handle]
	if ret then
		assert(ret.type == type)
		return ret
	end
	local t = snax.interface(type)
	ret = wrapper(handle, type, t)
	handle_cache[handle] = ret
	return ret
end

-- "pingserver", "hello world"
function snax.newservice(name, ...)
	local handle = snax.rawnewservice(name, ...)
	return snax.bind(handle, name)
end

local function service_name(global, name, ...)
	if global == true then
		return name
	else
		return global
	end
end

function snax.uniqueservice(name, ...)
	local handle = assert(skynet.call(".service", "lua", "LAUNCH", "snaxd", name, ...))
	-- 此handle是snaxd的handle，而不是name对应service的handle
	return snax.bind(handle, name)
end

function snax.globalservice(name, ...)
	local handle = assert(skynet.call(".service", "lua", "GLAUNCH", "snaxd", name, ...))
	return snax.bind(handle, name)
end

function snax.queryservice(name)
	local handle = assert(skynet.call(".service", "lua", "QUERY", "snaxd", name))
	-- 此handle是snaxd的handle，而不是name对应service的handle
	return snax.bind(handle, name)
end

function snax.queryglobal(name)
	local handle = assert(skynet.call(".service", "lua", "GQUERY", "snaxd", name))
	return snax.bind(handle, name)
end

function snax.kill(obj, ...)
	local t = snax.interface(obj.type)
	skynet_call(obj.handle, "snax", t.system.exit, ...)
end

function snax.self()
	return snax.bind(skynet.self(), SERVICE_NAME)
end

function snax.exit(...)
	snax.kill(snax.self(), ...)
end

local function test_result(ok, ...)
	if ok then
		return ...
	else
		error(...)
	end
end

function snax.hotfix(obj, source, ...)
	local t = snax.interface(obj.type)
	return test_result(skynet_call(obj.handle, "snax", t.system.hotfix, source, ...))
end

function snax.printf(fmt, ...)
	skynet.error(string.format(fmt, ...))
end

return snax
