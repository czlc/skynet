-- 代理服务，本来是直接发给clusterd并且带node和address的，通过这个代理，调用者
-- 不用关心node和address，也对clusterd也不用关心，就像访问本地服务一样
local skynet = require "skynet"
local cluster = require "cluster"
require "skynet.manager"	-- inject skynet.forward_type

local node, address = ...

skynet.register_protocol {
	name = "system",
	id = skynet.PTYPE_SYSTEM,
	unpack = function (...) return ... end,	-- 转发不需要解包，由调用者解包
}

local forward_map = {
	[skynet.PTYPE_SNAX] = skynet.PTYPE_SYSTEM,
	[skynet.PTYPE_LUA] = skynet.PTYPE_SYSTEM,
	[skynet.PTYPE_RESPONSE] = skynet.PTYPE_RESPONSE,	-- don't free response message，见skynet.forward_type，因为return 的消息还要留着转发。凡是在这个表中的都不会删除
}

skynet.forward_type( forward_map ,function()
	local clusterd = skynet.uniqueservice("clusterd")
	local n = tonumber(address)
	if n then
		address = n
	end
	-- 对于system类型的消息转发,由clusterd负责删除(默认不是forward callback都会自动删除)
	-- rawcall会挂起来等待回应，RESPONSE消息到来以后还需要保留以便之后返回给发送"system"的请求者，所以don't free response message
	skynet.dispatch("system", function (session, source, msg, sz)
		if session == 0 then
			skynet.send(clusterd, "lua", "push", node, address, msg, sz)
		else
			skynet.ret(skynet.rawcall(clusterd, "lua", skynet.pack("req", node, address, msg, sz)))
		end
	end)
end)
