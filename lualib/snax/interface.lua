local skynet = require "skynet"

-- 函数功能：加载指定snax service脚本，并将脚本中的接口按规则放到func中并返回
-- func[id] = {id, group, fname, function}
-- 包括全局函数init, exit, hotfix、accept.xxx、response.xxx
-- 其余全局函数加载到G下面
return function (name , G, loader)
	loader = loader or loadfile
	local mainfunc

	local function func_id(id, group)
		local tmp = {}
		local function count( _, name, func)
			if type(name) ~= "string" then
				error (string.format("%s method only support string", group))
			end
			if type(func) ~= "function" then
				error (string.format("%s.%s must be function"), group, name)
			end
			if tmp[name] then
				error (string.format("%s.%s duplicate definition", group, name))
			end
			tmp[name] = true
			table.insert(id, { #id + 1, group, name, func} )
		end
		return setmetatable({}, { __newindex = count })
	end

	do
		assert(getmetatable(G) == nil)
		assert(G.init == nil)
		assert(G.exit == nil)

		assert(G.accept == nil)
		assert(G.response == nil)
	end

	local temp_global = {}
	local env = setmetatable({} , { __index = temp_global })
	local func = {}

	local system = { "init", "exit", "hotfix" }

	do
		for k, v in ipairs(system) do
			system[v] = k
			func[k] = { k , "system", v }
		end
	end

	env.accept = func_id(func, "accept") -- accept 表在加入新元素__newindex的时候会将其插入到func中
	env.response = func_id(func, "response")

	local function init_system(t, name, f)
		local index = system[name] -- id
		if index then
			if type(f) ~= "function" then
				error (string.format("%s must be a function", name))
			end
			func[index][4] = f
		else
			temp_global[name] = f -- 不属于system的全局函数，不加到func中来
		end
	end

	local pattern

	do
		local path = assert(skynet.getenv "snax" , "please set snax in config file")

		local errlist = {}

		for pat in string.gmatch(path,"[^;]+") do
			local filename = string.gsub(pat, "?", name)
			local f , err = loader(filename, "bt", G)
			if f then
				pattern = pat
				mainfunc = f
				break
			else
				table.insert(errlist, err)
			end
		end

		if mainfunc == nil then
			error(table.concat(errlist, "\n"))
		end
	end

	setmetatable(G,	{ __index = env , __newindex = init_system })
	local ok, err = pcall(mainfunc)	-- 这个时候之前设置的__newindex，包括system和response、accept都会生效
	setmetatable(G, nil) -- 和env，_newindex断开关系，因为__newindex调用过后，东西都放到func中去了
	assert(ok,err)

	-- 对于不在func中的东西，放到G中来
	for k,v in pairs(temp_global) do
		G[k] = v
	end

	return func, pattern
end
