-- https://github.com/cloudwu/skynet/wiki/DataCenter
-- 当你需要跨节点通讯时，虽然只要持有其它节点的地址，就可以发送消息。但地址如何获得，却是一个问题。
-- 类似一个全网络共享的注册表
local skynet = require "skynet"

local datacenter = {}

function datacenter.get(...)
	return skynet.call("DATACENTER", "lua", "QUERY", ...)
end

function datacenter.set(...)
	return skynet.call("DATACENTER", "lua", "UPDATE", ...)
end

function datacenter.wait(...)
	return skynet.call("DATACENTER", "lua", "WAIT", ...)
end

return datacenter

