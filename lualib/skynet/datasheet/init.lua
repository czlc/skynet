local skynet = require "skynet"
local service = require "skynet.service"
local core = require "skynet.datasheet.core"

local datasheet_svr

skynet.init(function()
	datasheet_svr = service.query "datasheet"
end)

local datasheet = {}	-- [name] = {object = tb }
local sheets = setmetatable({}, {
	__gc = function(t)
		for _,v in pairs(t) do
			skynet.send(datasheet_svr, "lua", "release", v.handle)
		end
	end,
})

-- 得到指针
local function querysheet(name)
	return skynet.call(datasheet_svr, "lua", "query", name)
end

-- 一次 new，之后都是 update
local function updateobject(name)
	local t = sheets[name]
	if not t.object then
		t.object = core.new(t.handle)	-- 创建一个挂接 metatable 的 table，根据 table 可以找到 proxy
	end

	-- 监视 handle 被修改
	local function monitor()
		local handle = t.handle
		local newhandle = skynet.call(datasheet_svr, "lua", "monitor", handle)
		core.update(t.object, newhandle)
		t.handle = newhandle
		skynet.send(datasheet_svr, "lua", "release", handle)	-- 释放老的 handle
		return monitor()	-- 继续监视
	end
	skynet.fork(monitor)
end

function datasheet.query(name)
	local t = sheets[name]
	if not t then
		t = {}	-- 没有的话创建一个空表
		sheets[name] = t
	end
	if t.error then	-- 发送过错误
		error(t.error)
	end
	if t.object then	-- 已经查过此对象，直接使用，即使它被更新，还是可以用，只是里面的 handle 被改了
		return t.object
	end
	if t.queue then
		local co = coroutine.running()
		table.insert(t.queue, co)
		skynet.wait(co)
	else
		t.queue = {}	-- create wait queue for other query
		local ok, handle = pcall(querysheet, name)
		if ok then
			t.handle = handle
			updateobject(name)
		else
			t.error = handle
		end
		local q = t.queue
		t.queue = nil
		for _, co in ipairs(q) do
			skynet.wakeup(co)
		end
	end
	if t.error then
		error(t.error)
	end
	return t.object
end

return datasheet
