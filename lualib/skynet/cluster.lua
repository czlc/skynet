local skynet = require "skynet"

local clusterd
local cluster = {}

function cluster.call(node, address, ...)
	-- skynet.pack(...) will free by cluster.core.packrequest
	return skynet.call(clusterd, "lua", "req", node, address, skynet.pack(...))
end

function cluster.send(node, address, ...)
	-- push is the same with req, but no response
	skynet.send(clusterd, "lua", "push", node, address, skynet.pack(...))
end

function cluster.open(port)
	if type(port) == "string" then
		skynet.call(clusterd, "lua", "listen", port)
	else
		skynet.call(clusterd, "lua", "listen", "0.0.0.0", port)
	end
end

function cluster.reload(config)
	skynet.call(clusterd, "lua", "reload", config)
end

-- 生成一个本地代理。之后，就可以像访问一个本地服务一样，和这个远程服务通讯。
-- 返回这个代理的handle，"clusterproxy"
function cluster.proxy(node, name)
	return skynet.call(clusterd, "lua", "proxy", node, name)
end

function cluster.snax(node, name, address)
	local snax = require "skynet.snax"
	if not address then
		address = cluster.call(node, ".service", "QUERY", "snaxd" , name)
	end
	local handle = skynet.call(clusterd, "lua", "proxy", node, address)
	return snax.bind(handle, name)
end

-- 把 addr 注册为 cluster 可见的一个字符串名字 name 。如果不传 addr 表示把自身注册为 name 
function cluster.register(name, addr)
	assert(type(name) == "string")
	assert(addr == nil or type(addr) == "number")
	return skynet.call(clusterd, "lua", "register", name, addr)
end

-- 查询指定结点node下name指定的服务
function cluster.query(node, name)
	return skynet.call(clusterd, "lua", "req", node, 0, skynet.pack(name))
end

skynet.init(function()
	clusterd = skynet.uniqueservice("clusterd")	-- 本节点唯一
end)

return cluster
