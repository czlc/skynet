local skynet = require "skynet"

-- 加载指定 name 的脚本
local function dft_loader(path, name, G)
    local errlist = {}

    for pat in string.gmatch(path,"[^;]+") do
        local filename = string.gsub(pat, "?", name)
        local f , err = loadfile(filename, "bt", G)
        if f then
            return f, pat
        else
            table.insert(errlist, err)
        end
    end

    error(table.concat(errlist, "\n"))
end

return function (name, G, loader)
       loader = loader or dft_loader
       local mainfunc

	-- 返回一个table，向这个table添加函数的时候会将加入的函数转而
	-- 添加进传入的 func 表
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

	-- 初始化
	local temp_global = {}
	local env = setmetatable({} , { __index = temp_global })
	local func = {}	-- 所有的函数都将加入其中

	local system = { "init", "exit", "hotfix", "profile"}

	do
		for k, v in ipairs(system) do
			system[v] = k
			func[k] = { k , "system", v }	-- func[1] = {1, "system", "init" }
		end
	end

	-- 之后向env.accept 赋值 将加入到 func[idx] = {#func + 1, "accept", fname, f}
	env.accept = func_id(func, "accept")
	-- 之后向env.response 赋值 将加入到func[idx] = {#func + 1, "response", fname, f}
	env.response = func_id(func, "response")

	-- 之后向G添加东西，将会加入到func[]
	local function init_system(t, name, f)
		local index = system[name] -- id
		if index then
			-- 是系统函数:"init"、"exit"、"hotfix", "profile" 之一
			if type(f) ~= "function" then
				error (string.format("%s must be a function", name))
			end
			func[index][4] = f	-- [1] id, [2] group, [3] name, [4] f。前面3个之前都已经设置了
		else
			temp_global[name] = f -- 不属于系统函数，不加到func中来
		end
	end

	local pattern

	local path = assert(skynet.getenv "snax" , "please set snax in config file")
	mainfunc, pattern = loader(path, name, G)

	setmetatable(G,	{ __index = env , __newindex = init_system })
	local ok, err = xpcall(mainfunc, debug.traceback)	-- 这个时候之前load设置的__newindex，包括system和response、accept都会生效
	setmetatable(G, nil) -- 和env，_newindex断开关系，因为__newindex调用过后，东西都放到func中去了
	assert(ok,err)

	-- 对于不在func中的东西，放到G中来
	for k,v in pairs(temp_global) do
		G[k] = v
	end

	return func, pattern
end
