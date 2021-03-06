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

-- 获得一个name所指定的snax service的接口，并按规则存放
function snax.interface(name)
	if typeclass[name] then
		return typeclass[name]
	end

	local si = snax_interface(name, G)	-- 分析name所指定的服务的接口，并按accept, response, system存放

	-- 得到的接口按规则存放
	local ret = {
		name = name,	-- snax 服务的名字
		accept = {},	-- accept 前缀表示这个方法没有回应，调用者通过post调用
		response = {},  -- response 前缀表示这个方法一定有一个回应，调用者通过req调用
		system = {},	-- 一些全局函数，比如init、exit，这些方法没有回应，类似accept
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

-- 对调用接口的封装，拥有post和req接口
-- 注意snaxd是被被调用者的封装有accept和respone接口
local function wrapper(handle, name, type)
	return setmetatable ({
		post = gen_post(type, handle),	-- 使得post.xxx()函数调用 是发送消息到snaxd
		req = gen_req(type, handle),	-- 使得req.xxx()函数调用 是发消息到snaxd
		type = name,
		handle = handle,
		}, meta)
end

local handle_cache = setmetatable( {} , { __mode = "kv" } ) -- cache 所有的snaxd服务

-- 启动一个snaxd服务，并初始化它
-- name:snax service name，比如pingserver
function snax.rawnewservice(name, ...)
	local t = snax.interface(name)
	local handle = skynet.newservice("snaxd", name) -- 启动一个snaxd服务，它是对name所指定服务的一个包装
	assert(handle_cache[handle] == nil)
	if t.system.init then
		skynet.call(handle, "snax", t.system.init, ...)
	end
	return handle
end

-- 绑定snaxd服务和它相关real service
-- 返回的对象有req和和post2个table，它们下面又挂接了请求方法
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

-- name:snax service name，比如pingserver
function snax.newservice(name, ...)
	local handle = snax.rawnewservice(name, ...)
	return snax.bind(handle, name)
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

function snax.profile_info(obj)
	local t = snax.interface(obj.type)
	return skynet_call(obj.handle, "snax", t.system.profile)
end

return snax
