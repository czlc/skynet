-- 所有服务尽量做成无状态服务
local c = require "skynet.core"
local tostring = tostring
local tonumber = tonumber
local coroutine = coroutine
local assert = assert
local pairs = pairs
local pcall = pcall

local profile = require "profile"

local coroutine_resume = profile.resume
local coroutine_yield = profile.yield

local proto = {}
local skynet = {
	-- read skynet.h
	PTYPE_TEXT = 0,
	PTYPE_RESPONSE = 1,
	PTYPE_MULTICAST = 2,
	PTYPE_CLIENT = 3,
	PTYPE_SYSTEM = 4,
	PTYPE_HARBOR = 5,
	PTYPE_SOCKET = 6,
	PTYPE_ERROR = 7,
	PTYPE_QUEUE = 8,	-- used in deprecated mqueue, use skynet.queue instead
	PTYPE_DEBUG = 9,
	PTYPE_LUA = 10,
	PTYPE_SNAX = 11,
}

-- code cache
skynet.cache = require "skynet.codecache"

-- class.dispatch的参数为session, source, p.unpack(msg, sz, ...)
function skynet.register_protocol(class)
	local name = class.name
	local id = class.id
	assert(proto[name] == nil)
	assert(type(name) == "string" and type(id) == "number" and id >=0 and id <=255)
	proto[name] = class
	proto[id] = class
end

local session_id_coroutine = {}			-- [session] = co，等待对方(session)回应的co数组，co是发送了请求被yield的协程，因为等待回应是通过sesion做标识，所以session为key
local session_coroutine_id = {}			-- [co] = session，等待回应对方(session)的co数组，co是收到了session的请求，等待自身处理完成的协程回应对方,收到了对方的请求，用co来执行请求，请求执行完了，根据这个co可以找到回复谁，所以key是co
local session_coroutine_address = {}	-- [co] = addr，等待回应对方的地址，和session_coroutine_id配套使用
local session_response = {}				-- [co] = closure，本服务待回应的请求，调用closure的时候会回应 http://blog.codingnow.com/2014/07/skynet_response.html
local unresponse = {}					-- [closure] = true/false，记录等待调用的闭包，用于退出的时候返回通知等待方？

local wakeup_session = {}				-- [co] = true 已经醒来的协程等待执行
local sleep_session = {}				-- [co] = true 睡眠中的协程

local watching_service = {}				-- 所关注的服务，[co] = ref
local watching_session = {}				-- 监控yield_call正在等待回应的session，[session] = service，service为目标服务的addr
local dead_service = {}					-- 记录已经无效的服务
local error_queue = {}					-- 出错的session
local fork_queue = {}

-- suspend is function
local suspend

-- 十六进制地址转number
local function string_to_handle(str)
	return tonumber("0x" .. string.sub(str, 2))	-- 去掉十六进制地址前面的":"
end

----- monitor exit

local function dispatch_error_queue()
	local session = table.remove(error_queue,1)
	if session then
		local co = session_id_coroutine[session]
		session_id_coroutine[session] = nil
		return suspend(co, coroutine_resume(co, false))
	end
end

-- error_source所指向的服务出了状况
local function _error_dispatch(error_session, error_source)
	if error_session == 0 then
		-- service is down
		--  Don't remove from watching_service , because user may call dead service
		if watching_service[error_source] then
			dead_service[error_source] = true
		end
		for session, srv in pairs(watching_session) do
			if srv == error_source then
				table.insert(error_queue, session) -- 如果正在等待error_source所指定的服务返回，那么可以不用等了，不过error_source可以是任意格式的地址
			end
		end
	else
		-- capture an error for error_session
		if watching_session[error_session] then
			table.insert(error_queue, error_session)
		end
	end
end

-- coroutine reuse http://blog.codingnow.com/2013/07/coroutine_reuse.html

local coroutine_pool = {}

local function co_create(f)
	local co = table.remove(coroutine_pool)
	if co == nil then
		co = coroutine.create(function(...)
			f(...)
			while true do
				f = nil	-- for gc
				coroutine_pool[#coroutine_pool+1] = co	-- 放到协程池中供之后复用
				f = coroutine_yield "EXIT" -- 挂起本协程，待以后复用。复用的时候，调用楼下的resume(co, f)的时候yield立即返回，返回值就是resume传入的f
				f(coroutine_yield())	   -- 但是先暂时挂起来，不继续执行，等再次调用resume的时候才执行,因为这是coroutine.create的语义
			end
		end)
	else
		coroutine_resume(co, f)
	end
	return co
end

local function dispatch_wakeup()
	local co = next(wakeup_session)
	if co then
		wakeup_session[co] = nil
		local session = sleep_session[co]
		if session then
			session_id_coroutine[session] = "BREAK"			-- 打断sleep，继续执行
			return suspend(co, coroutine_resume(co, false, "BREAK"))
		end
	end
end

local function release_watching(address)
	local ref = watching_service[address]
	if ref then
		ref = ref - 1
		if ref > 0 then
			watching_service[address] = ref
		else
			watching_service[address] = nil
		end
	end
end

-- suspend is local function
-- suspend的用法 suspend(co, coroutine.resume(co, ...))
-- resume 返回的都是ret, command, ....(通过yield返回，即使退出也会走到co_create里面的EXIT命令)
-- 任何co的挂起(resume的返回)都必须走到suspend来，用于管理何时再resume该co
function suspend(co, result, command, param, size)
	if not result then	-- 协程执行过程中出错啦，错误处理
		local session = session_coroutine_id[co]
		if session then -- coroutine may fork by others (session is nil)
			local addr = session_coroutine_address[co]
			if session ~= 0 then
				-- only call response error
				c.send(addr, skynet.PTYPE_ERROR, session, "")
			end
			session_coroutine_id[co] = nil
			session_coroutine_address[co] = nil
		end
		error(debug.traceback(co,tostring(command))) -- command 是错误信息
	end
	if command == "CALL" then
		session_id_coroutine[param] = co
	elseif command == "SLEEP" then
		session_id_coroutine[param] = co
		sleep_session[co] = param
	elseif command == "RETURN" then	-- 结果返回给请求者
		local co_session = session_coroutine_id[co]
		local co_address = session_coroutine_address[co]
		if param == nil or session_response[co] then
			error(debug.traceback(co))
		end
		session_response[co] = true
		local ret
		if not dead_service[co_address] then
			ret = c.send(co_address, skynet.PTYPE_RESPONSE, co_session, param, size) ~= nil
			if not ret then
				-- If the package is too large, returns nil. so we should report error back
				c.send(co_address, skynet.PTYPE_ERROR, co_session, "")
			end
		elseif size ~= nil then
			c.trash(param, size)
			ret = false
		end
		return suspend(co, coroutine_resume(co, ret)) -- send 的结果返回调用skynet.ret的地方
	elseif command == "RESPONSE" then
		local co_session = session_coroutine_id[co]
		local co_address = session_coroutine_address[co]
		if session_response[co] then
			error(debug.traceback(co))
		end
		local f = param -- pack函数
		local function response(ok, ...)
			if ok == "TEST" then
				if dead_service[co_address] then
					release_watching(co_address)
					unresponse[response] = nil
					f = false
					return false
				else
					return true
				end
			end
			if not f then
				if f == false then
					f = nil
					return false
				end
				error "Can't response more than once"
			end

			local ret
			if not dead_service[co_address] then
				if ok then
					ret = c.send(co_address, skynet.PTYPE_RESPONSE, co_session, f(...)) ~= nil
					if not ret then
						-- If the package is too large, returns false. so we should report error back
						c.send(co_address, skynet.PTYPE_ERROR, co_session, "")
					end
				else
					ret = c.send(co_address, skynet.PTYPE_ERROR, co_session, "") ~= nil
				end
			else
				ret = false
			end
			release_watching(co_address)
			unresponse[response] = nil
			f = nil
			return ret
		end
		watching_service[co_address] = watching_service[co_address] + 1
		session_response[co] = true
		unresponse[response] = true
		return suspend(co, coroutine_resume(co, response))
	elseif command == "EXIT" then
		-- coroutine exit
		local address = session_coroutine_address[co]
		release_watching(address)
		session_coroutine_id[co] = nil
		session_coroutine_address[co] = nil
		session_response[co] = nil
	elseif command == "QUIT" then
		-- service exit
		return
	elseif command == "USER" then
		-- See skynet.coutine for detail
		error("Call skynet.coroutine.yield out of skynet.coroutine.resume\n" .. debug.traceback(co))
	elseif command == nil then
		-- debug trace
		return
	else
		error("Unknown command : " .. command .. "\n" .. debug.traceback(co))
	end
	dispatch_wakeup()		-- 本协程挂起之后，可以唤醒其它协程
	dispatch_error_queue()	-- 等待的某些session因为对方原因不能正常返回
end

function skynet.timeout(ti, func)
	local session = c.intcommand("TIMEOUT",ti)
	assert(session)
	local co = co_create(func)
	assert(session_id_coroutine[session] == nil)
	session_id_coroutine[session] = co
end

function skynet.sleep(ti)
	local session = c.intcommand("TIMEOUT",ti)
	assert(session)
	local succ, ret = coroutine_yield("SLEEP", session)
	sleep_session[coroutine.running()] = nil
	if succ then
		return
	end
	if ret == "BREAK" then
		return "BREAK"
	else
		error(ret)
	end
end

function skynet.yield()
	return skynet.sleep(0)
end

function skynet.wait(co)
	local session = c.genid()
	local ret, msg = coroutine_yield("SLEEP", session)
	co = co or coroutine.running()
	sleep_session[co] = nil
	session_id_coroutine[session] = nil
end


-- 获得服务自己的地址
local self_handle
function skynet.self()
	if self_handle then
		return self_handle
	end
	self_handle = string_to_handle(c.command("REG"))
	return self_handle
end

-- 根据一个局部名字".xxxxxx"查找对应的handle
function skynet.localname(name)
	local addr = c.command("QUERY", name)
	if addr then
		return string_to_handle(addr)
	end
end

skynet.now = c.now

local starttime

function skynet.starttime()
	if not starttime then
		starttime = c.intcommand("STARTTIME")
	end
	return starttime
end

function skynet.time()
	return skynet.now()/100 + (starttime or skynet.starttime())
end

function skynet.exit()
	fork_queue = {}	-- no fork coroutine can be execute after skynet.exit
	skynet.send(".launcher","lua","REMOVE",skynet.self(), false)
	-- report the sources that call me
	for co, session in pairs(session_coroutine_id) do	-- 等待本服务返回的协程都退出
		local address = session_coroutine_address[co]	-- 对方地址
		if session~=0 and address then
			c.redirect(address, 0, skynet.PTYPE_ERROR, session, "")
		end
	end
	for resp in pairs(unresponse) do
		resp(false)
	end
	-- report the sources I call but haven't return
	local tmp = {}
	for session, address in pairs(watching_session) do
		tmp[address] = true
	end
	for address in pairs(tmp) do
		c.redirect(address, 0, skynet.PTYPE_ERROR, 0, "")
	end
	c.command("EXIT")
	-- quit service
	coroutine_yield "QUIT"
end

function skynet.getenv(key)
	local ret = c.command("GETENV",key)
	if ret == "" then
		return
	else
		return ret
	end
end

function skynet.setenv(key, value)
	c.command("SETENV",key .. " " ..value)
end

-- 这条 API 可以把一条类别为 typename 的消息发送给 address 。它会先经过事先注册的
--  pack 函数打包 ... 的内容。
-- skynet.send 是一条非阻塞 API ，发送完消息后，coroutine 会继续向下运行，这期间服
-- 务不会重入。
function skynet.send(addr, typename, ...)
	local p = proto[typename]
	return c.send(addr, p.id, 0 , p.pack(...))
end

skynet.genid = assert(c.genid)

-- 重定向，伪造source向dest发送消息
skynet.redirect = function(dest,source,typename,...)
	return c.redirect(dest, source, proto[typename].id, ...)
end

skynet.pack = assert(c.pack)
skynet.packstring = assert(c.packstring)
skynet.unpack = assert(c.unpack)
skynet.tostring = assert(c.tostring)
skynet.trash = assert(c.trash)

-- 挂起等待CALL请求的返回，在它之前一定有CALL请求发送出去
local function yield_call(service, session)
	watching_session[session] = service
	local succ, msg, sz = coroutine_yield("CALL", session)
	watching_session[session] = nil
	if not succ then
		error "call failed"
	end
	return msg,sz
end

-- 它会在内部生成一个唯一 session ，并向 address 提起请求，并阻塞等
-- 待对 session 的回应（可以不由 address 回应）。当消息回应后，还会
-- 通过之前注册的 unpack 函数解包。表面上看起来，就是发起了一次 RPC，
-- 并阻塞等待回应。
-- skynet.call 仅仅阻塞住当前的 coroutine ，而没有阻塞整个服务。在等待
-- 回应期间，服务照样可以相应其他请求。所以，尤其要注意，在 skynet.call
--  之前获得的服务内的状态，到返回后，很有可能改变
function skynet.call(addr, typename, ...)
	local p = proto[typename]
	local session = c.send(addr, p.id , nil , p.pack(...))
	if session == nil then
		error("call to invalid address " .. skynet.address(addr))
	end
	return p.unpack(yield_call(addr, session))
end

-- 向其它服务发起一个请求，并等待回应，数据和返回值没有pack和unpack
-- 只能在一个协程中发起
-- 返回值为yield_call
function skynet.rawcall(addr, typename, msg, sz)
	local p = proto[typename]
	local session = assert(c.send(addr, p.id , nil , msg, sz), "call to invalid address")
	return yield_call(addr, session)
end

-- 当本lua服务收到别的服务发来的请求的时候会创建一个co去执行相应的请求(raw_dispatch_message)
-- 在执行co的过程中，可以调用skynet.ret把结果返回给源服务，它之所以要用yield
-- 而不是直接send是因为要取得相应请求者的addr和session，而他们对目标服务来说它们是透明的。
-- 所以通过在suspend中得到，它们通常都是在dispatch函数中调用，因为dispatch就是处理别的服务发来的请求
-- 非阻塞 API
function skynet.ret(msg, sz)
	msg = msg or ""
	return coroutine_yield("RETURN", msg, sz)
end

--[[
	获得一个闭包，以后调用这个闭包即可把回应消息发回。这里的参数 skynet.pack 是可选的，你可以传入
	其它打包函数，默认即是 skynet.pack 。

	skynet.response 返回的闭包可用于延迟回应。调用它时，第一个参数通常是 true 表示是一个正常的回应
	，之后的参数是需要回应的数据。如果是 false ，则给请求者抛出一个异常。它的返回值表示回应的地址是
	否还有效。如果你仅仅想知道回应地址的有效性，那么可以在第一个参数传入 "TEST" 用于检测。
]]
-- 非阻塞 API
function skynet.response(pack)
	pack = pack or skynet.pack
	return coroutine_yield("RESPONSE", pack)
end

function skynet.retpack(...)
	return skynet.ret(skynet.pack(...))
end

-- 标记某sleep、wait的协程可以被唤醒
function skynet.wakeup(co)
	if sleep_session[co] and wakeup_session[co] == nil then
		wakeup_session[co] = true
		return true
	end
end

-- 设置proto[typename]的dispatch函数
function skynet.dispatch(typename, func)
	local p = proto[typename]
	if func then
		local ret = p.dispatch
		p.dispatch = func
		return ret
	else
		return p and p.dispatch
	end
end

local function unknown_request(session, address, msg, sz, prototype)
	skynet.error(string.format("Unknown request (%s): %s", prototype, c.tostring(msg,sz)))
	error(string.format("Unknown session : %d from %x", session, address))
end

function skynet.dispatch_unknown_request(unknown)
	local prev = unknown_request
	unknown_request = unknown
	return prev
end

local function unknown_response(session, address, msg, sz)
	skynet.error(string.format("Response message : %s" , c.tostring(msg,sz)))
	error(string.format("Unknown session : %d from %x", session, address))
end

function skynet.dispatch_unknown_response(unknown)
	local prev = unknown_response
	unknown_response = unknown
	return prev
end

function skynet.fork(func,...)
	local args = table.pack(...)
	local co = co_create(function()
		func(table.unpack(args,1,args.n))
	end)
	table.insert(fork_queue, co)
	return co
end

local function raw_dispatch_message(prototype, msg, sz, session, source)
	-- skynet.PTYPE_RESPONSE = 1, read skynet.h
	if prototype == 1 then -- 收到回应
		local co = session_id_coroutine[session]	-- 查找等待回应的协程
		if co == "BREAK" then						-- 此sleep协程已经被wakeup了
			session_id_coroutine[session] = nil
		elseif co == nil then
			unknown_response(session, source, msg, sz)
		else
			session_id_coroutine[session] = nil
			suspend(co, coroutine_resume(co, true, msg, sz))	-- 请求结果到了，继续执行协程
		end
	else
		local p = proto[prototype]
		if p == nil then
			if session ~= 0 then
				c.send(source, skynet.PTYPE_ERROR, session, "")
			else
				unknown_request(session, source, msg, sz, prototype)
			end
			return
		end
		local f = p.dispatch
		if f then
			-- 谁来请求关注谁
			local ref = watching_service[source]
			if ref then
				watching_service[source] = ref + 1
			else
				watching_service[source] = 1
			end
			local co = co_create(f)								-- 通过新开一个协程来处理请求
			session_coroutine_id[co] = session					-- 协程和请求Id关联
			session_coroutine_address[co] = source				-- 协程和请求来源管理
			suspend(co, coroutine_resume(co, session,source, p.unpack(msg,sz))) -- 协程开始处理，resume返回则挂起
		else
			unknown_request(session, source, msg, sz, proto[prototype].name)
		end
	end
end

function skynet.dispatch_message(...)
	local succ, err = pcall(raw_dispatch_message,...)
	while true do	-- 为何放在此处，如果重载了dispatch_message则fork的将不会被执行？
		local key,co = next(fork_queue)
		if co == nil then
			break
		end
		fork_queue[key] = nil
		local fork_succ, fork_err = pcall(suspend,co,coroutine_resume(co))
		if not fork_succ then
			if succ then
				succ = false
				err = tostring(fork_err)
			else
				err = tostring(err) .. "\n" .. tostring(fork_err)
			end
		end
	end
	assert(succ, tostring(err))
end

--[[
用于启动一个新的 Lua 服务。name 是脚本的名字（不用写 .lua 后缀）。
只有被启动的脚本的 start 函数返回后，这个 API 才会返回启动的服务的地址，这是一个阻塞 API 。

A服务通过launcher服务启动B服务，launcher服务开启服务B后保存一个延迟确认的闭包response；B启
动成功后，通知launcher服务LAUNCHOK了。launcher从而执行之前的延迟确认闭包，通知A，服务启动的
结果，这样的好处是launcher不用等B启动完成，可以去做别的事

注意：启动参数其实是以字符串拼接的方式传递过去的。所以不要在参数中传递复杂的 Lua 对象。接收到
的参数都是字符串，且字符串中不可以有空格（否则会被分割成多个参数）。这种参数传递方式是历史遗留
下来的，有很多潜在的问题。目前推荐的惯例是，让你的服务响应一个启动消息。在 newservice 之后，立
刻调用 skynet.call 发送启动请求。
]]
-- 阻塞函数
function skynet.newservice(name, ...)
	return skynet.call(".launcher", "lua" , "LAUNCH", "snlua", name, ...)
end

-- https://github.com/cloudwu/skynet/wiki/UniqueService
-- 很大程度上取代了具名服务（不再推荐使用的早期特性）的功能。
function skynet.uniqueservice(global, ...)
	if global == true then
		return assert(skynet.call(".service", "lua", "GLAUNCH", ...))
	else
		return assert(skynet.call(".service", "lua", "LAUNCH", global, ...))
	end
end

-- skynet.queryservice 来查询已有服务。如果这个服务不存在，这个 api 会一直阻塞到它启动好为止。
function skynet.queryservice(global, ...)
	if global == true then
		return assert(skynet.call(".service", "lua", "GQUERY", ...))
	else
		return assert(skynet.call(".service", "lua", "QUERY", global, ...))
	end
end

-- 用于把一个地址数字转换为一个可用于阅读的字符串
function skynet.address(addr)
	if type(addr) == "number" then
		return string.format(":%08x",addr)
	else
		return tostring(addr)
	end
end

function skynet.harbor(addr)
	return c.harbor(addr)
end

-- 向logger服务发送一条信息
function skynet.error(...)
	local t = {...}
	for i=1,#t do
		t[i] = tostring(t[i])
	end
	return c.error(table.concat(t, " "))
end

----- register protocol
-- 以下各个协议类型是大部分lua服务都会有的
do
	local REG = skynet.register_protocol

	-- lua的dispatch由各个服务定制
	REG {
		name = "lua",
		id = skynet.PTYPE_LUA,
		pack = skynet.pack,
		unpack = skynet.unpack,
	}

	-- 某个服务想回应source服务，可以通过skynet.send "response" 类型的消息，但是更简单的方法是用ret
	REG {
		name = "response",
		id = skynet.PTYPE_RESPONSE,
	}

	REG {
		name = "error",
		id = skynet.PTYPE_ERROR,
		unpack = function(...) return ... end,
		dispatch = _error_dispatch,
	}
end

local init_func = {}

--[[
	这通常用于 lua 库的编写。你需要编写的服务引用你的库的时候，事先调用一些 skynet 阻塞 API ，
	就可以用 skynet.init 把这些工作注册在 start 之前。
]]
function skynet.init(f, name)
	assert(type(f) == "function")
	if init_func == nil then
		f()
	else
		if name == nil then
			table.insert(init_func, f)
		else
			assert(init_func[name] == nil)
			init_func[name] = f
		end
	end
end

local function init_all()
	local funcs = init_func
	init_func = nil
	if funcs then
		for k,v in pairs(funcs) do
			v()
		end
	end
end

local function ret(f, ...)
	f()
	return ...
end

local function init_template(start)
	init_all()
	init_func = {}
	return ret(init_all, start())
end

function skynet.pcall(start)
	return xpcall(init_template, debug.traceback, start)
end

function skynet.init_service(start)
	local ok, err = skynet.pcall(start)
	if not ok then
		skynet.error("init service failed: " .. tostring(err))
		skynet.send(".launcher","lua", "ERROR")
		skynet.exit()
	else
		skynet.send(".launcher","lua", "LAUNCHOK")	-- A服务通过launcher服务启动B服务，launcher服务开启服务B后保存一个延迟确认的闭包response；B执行到这里说明成功启动了，通知launcher服务LAUNCHOK了。launcher从而执行之前的延迟确认闭包，通知A，服务启动的结果
	end
end

function skynet.start(start_func)
	c.callback(skynet.dispatch_message)	-- 设置消息分发函数
	skynet.timeout(0, function()
		skynet.init_service(start_func)
	end)
end

function skynet.endless()
	return c.command("ENDLESS")~=nil
end

function skynet.mqlen()
	return c.intcommand "MQLEN"
end

function skynet.task(ret)
	local t = 0
	for session,co in pairs(session_id_coroutine) do
		if ret then
			ret[session] = debug.traceback(co)
		end
		t = t + 1
	end
	return t
end

function skynet.term(service)
	return _error_dispatch(0, service)
end

local function clear_pool()
	coroutine_pool = {}
end

-- Inject internal debug framework
local debug = require "skynet.debug"
debug(skynet, {
	dispatch = skynet.dispatch_message,
	clear = clear_pool,
	suspend = suspend,
})

return skynet
