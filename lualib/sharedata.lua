local skynet = require "skynet"
local sd = require "sharedata.corelib"

local service

skynet.init(function()
	service = skynet.uniqueservice "sharedatad"
end)

local sharedata = {}

-- obj 是box 后的
local function monitor(name, obj, cobj)
	local newobj = cobj
	while true do
		newobj = skynet.call(service, "lua", "monitor", name, newobj)
		if newobj == nil then
			break
		end
		sd.update(obj, newobj)
	end
end

function sharedata.query(name)
	local obj = skynet.call(service, "lua", "query", name)	-- 获得name对于table的cobj
	local r = sd.box(obj)
	skynet.send(service, "lua", "confirm" , obj)
	skynet.fork(monitor,name, r, obj)
	return r
end

-- 创建一个sharedata对象，v可以是一个table，一段lua代码，一个文件名或者是nil
function sharedata.new(name, v, ...)
	skynet.call(service, "lua", "new", name, v, ...)
end

function sharedata.update(name, v, ...)
	skynet.call(service, "lua", "update", name, v, ...)
end

function sharedata.delete(name)
	skynet.call(service, "lua", "delete", name)
end

return sharedata
