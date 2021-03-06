local skynet = require "skynet"

local harbor = {}

-- 注册一个全局名字。如果 handle 为空，则注册自己
function harbor.globalname(name, handle)
	handle = handle or skynet.self()
	skynet.send(".cslave", "lua", "REGISTER", name, handle)
end

-- 可以用来查询全局名字或本地名字对应的服务地址。它是一个阻塞调用。
function harbor.queryname(name)
	return skynet.call(".cslave", "lua", "QUERYNAME", name)
end

-- 用来监控一个 slave 是否断开。如果 harbor id 对应的 slave 正常，这个 api 将阻塞。当 slave 断开时，会立刻返回
function harbor.link(id)
	skynet.call(".cslave", "lua", "LINK", id)
end

--  和 harbor.link 相反。如果 harbor id 对应的 slave 没有连接，这个 api 将阻塞，一直到它连上来才返回
function harbor.connect(id)
	skynet.call(".cslave", "lua", "CONNECT", id)
end

-- 监控MASTER是否断开
function harbor.linkmaster()
	skynet.call(".cslave", "lua", "LINKMASTER")
end

return harbor
