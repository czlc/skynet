local skynet = require "skynet"
local sharedata = require "sharedata.corelib"
local table = table
local cache = require "skynet.codecache"
cache.mode "OFF"	-- turn off codecache, because CMD.new may load data file

local NORET = {}
local pool = {}
local pool_count = {}
local objmap = {}			-- [cobj] = { value = tbl , obj = cobj, watch = {} }，便于查找

-- tbl 是需要共享的lua table
local function newobj(name, tbl)
	assert(pool[name] == nil)
	local cobj = sharedata.host.new(tbl)	-- 将tbl保存为可共享的lightuserdata
	sharedata.host.incref(cobj)
	local v = { value = tbl , obj = cobj, watch = {} }
	objmap[cobj] = v
	pool[name] = v
	pool_count[name] = { n = 0, threshold = 16 }	-- n 是监控者数目，threshold是监控者上限
end

local function collectobj()
	while true do
		skynet.sleep(600 * 100)	-- sleep 10 min
		collectgarbage()
		for obj, v in pairs(objmap) do
			if v == true then
				if sharedata.host.getref(obj) <= 0  then
					objmap[obj] = nil
					sharedata.host.delete(obj)
				end
			end
		end
	end
end

local CMD = {}

local env_mt = { __index = _ENV }

function CMD.new(name, t, ...)
	local dt = type(t)
	local value
	if dt == "table" then
		-- 可以是一张 lua table ，但不可以有环。且 key 必须是字符串和正整数
		value = t
	elseif dt == "string" then
		value = setmetatable({}, env_mt)
		local f
		if t:sub(1,1) == "@" then
			-- 也可以是一个文件
			f = assert(loadfile(t:sub(2),"bt",value))	-- Q:liuchang 为何不直接传入_ENV，因为代码中可能会修改当前_ENV?
		else
			-- 还可以是一段 lua 文本代码
			f = assert(load(t, "=" .. name, "bt", value))
		end
		local _, ret = assert(skynet.pcall(f, ...))
		setmetatable(value, nil)
		if type(ret) == "table" then
			value = ret
		end
	elseif dt == "nil" then
		value = {}
	else
		error ("Unknown data type " .. dt)
	end
	newobj(name, value)
end

function CMD.delete(name)
	local v = assert(pool[name])
	pool[name] = nil
	pool_count[name] = nil
	assert(objmap[v.obj])
	objmap[v.obj] = true
	sharedata.host.decref(v.obj)
	for _,response in pairs(v.watch) do
		response(true)
	end
end

-- 获得指定的cobj
function CMD.query(name)
	local v = assert(pool[name])
	local obj = v.obj
	sharedata.host.incref(obj)
	return v.obj
end

-- 查询结束，减引用
function CMD.confirm(cobj)
	if objmap[cobj] then
		sharedata.host.decref(cobj)
	end
	return NORET
end

function CMD.update(name, t, ...)
	local v = pool[name]
	local watch, oldcobj
	if v then
		watch = v.watch
		oldcobj = v.obj
		objmap[oldcobj] = true
		sharedata.host.decref(oldcobj)
		pool[name] = nil
		pool_count[name] = nil
	end
	CMD.new(name, t, ...)
	local newobj = pool[name].obj
	if watch then
		sharedata.host.markdirty(oldcobj)
		for _,response in pairs(watch) do
			response(true, newobj)
		end
	end
end

local function check_watch(queue)
	local n = 0
	for k,response in pairs(queue) do
		if not response "TEST" then
			-- 统计无效的监控
			queue[k] = nil
			n = n + 1
		end
	end
	return n
end

-- 监控 cobj是否有变化
function CMD.monitor(name, obj)
	local v = assert(pool[name])
	if obj ~= v.obj then
		return v.obj
	end

	local n = pool_count[name].n + 1
	if n > pool_count[name].threshold then
		n = n - check_watch(v.watch)
		pool_count[name].threshold = n * 2
	end
	pool_count[name].n = n

	table.insert(v.watch, skynet.response())

	return NORET
end

skynet.start(function()
	skynet.fork(collectobj)
	skynet.dispatch("lua", function (session, source ,cmd, ...)
		local f = assert(CMD[cmd])
		local r = f(...)
		if r ~= NORET then
			skynet.ret(skynet.pack(r))
		end
	end)
end)

