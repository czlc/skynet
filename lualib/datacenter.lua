-- https://github.com/cloudwu/skynet/wiki/DataCenter
-- 当你需要跨节点通讯时，虽然只要持有其它节点的地址，就可以发送消息。但地址如何获得，却是一个问题。
-- 类似一个全网络共享的注册表
local skynet = require "skynet"

local datacenter = {}

-- 从 key1.key2 读一个值。这个 api 至少需要一个参数，如果传入多个参数，则用来读出树的一个分支。
function datacenter.get(...)
	return skynet.call("DATACENTER", "lua", "QUERY", ...)
end

-- 可以向 key1.key2 设置一个值 value 。这个 api 至少需要两个参数，没有特别限制树结构的层级数。
function datacenter.set(...)
	return skynet.call("DATACENTER", "lua", "UPDATE", ...)
end

--同 get 方法，但如果读取的分支为 nil 时，这个函数会阻塞，直到有人更新这个分支才返回
-- wait 必须作用于一个叶节点，不能等待一个分支。
function datacenter.wait(...)
	return skynet.call("DATACENTER", "lua", "WAIT", ...)
end

return datacenter

