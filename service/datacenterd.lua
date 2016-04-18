local skynet = require "skynet"

local command = {}
local database = {}
local wait_queue = {}
local mode = {}

local function query(db, key, ...)
	if key == nil then
		return db
	else
		return query(db[key], ...)
	end
end

function command.QUERY(key, ...)
	local d = database[key]
	if d then
		return query(d, ...)
	end
end

local function update(db, key, value, ...)
	if select("#",...) == 0 then
		local ret = db[key]
		db[key] = value
		return ret, value	-- old,new
	else
		if db[key] == nil then
			db[key] = {}
		end
		return update(db[key], value, ...)
	end
end

local function wakeup(db, key1, ...)
	if key1 == nil then
		return
	end
	local q = db[key1]
	if q == nil then
		return
	end
	-- "queue" 表明到了一个叶节点
	if q[mode] == "queue" then
		db[key1] = nil	-- 找到了从wait_queue中拿出去
		if select("#", ...) ~= 1 then
			-- throw error because can't wake up a branch
			for _,response in ipairs(q) do
				response(false)
			end
		else
			return q
		end
	else
		-- it's branch
		return wakeup(q , ...)
	end
end

function command.UPDATE(...)
	local ret, value = update(database, ...)
	if ret or value == nil then  -- ret表明之前有值，没有因此阻塞的，value == nil表明没有设置有效的值，也不用唤醒等待的协程
		return ret
	end
	local q = wakeup(wait_queue, ...)	-- 获得wait队列
	if q then
		for _, response in ipairs(q) do
			response(true,value)
		end
	end
end

local function waitfor(db, key1, key2, ...)
	if key2 == nil then
		-- 表明key1是叶结点
		-- push queue
		local q = db[key1]
		if q == nil then
			q = { [mode] = "queue" }	-- queue 表明这属于叶结点
			db[key1] = q
		else
			assert(q[mode] == "queue")
		end
		table.insert(q, skynet.response())	-- 等待此叶结点的协程
	else
		local q = db[key1]
		if q == nil then
			q = { [mode] = "branch" }
			db[key1] = q
		else
			assert(q[mode] == "branch")
		end
		return waitfor(q, key2, ...)
	end
end

skynet.start(function()
	skynet.dispatch("lua", function (_, _, cmd, ...)
		if cmd == "WAIT" then
			local ret = command.QUERY(...)
			if ret then
				skynet.ret(skynet.pack(ret))
			else
				waitfor(wait_queue, ...) -- 没有查到，等待结果
			end
		else
			local f = assert(command[cmd])
			skynet.ret(skynet.pack(f(...)))
		end
	end)
end)
