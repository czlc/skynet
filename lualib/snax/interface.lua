local skynet = require "skynet"

-- ����ָ�� name �Ľű�
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

	-- ����һ��table�������table��Ӻ�����ʱ��Ὣ����ĺ���ת��
	-- ��ӽ������ func ��
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

	-- ��ʼ��
	local temp_global = {}
	local env = setmetatable({} , { __index = temp_global })
	local func = {}	-- ���еĺ���������������

	local system = { "init", "exit", "hotfix", "profile"}

	do
		for k, v in ipairs(system) do
			system[v] = k
			func[k] = { k , "system", v }	-- func[1] = {1, "system", "init" }
		end
	end

	-- ֮����env.accept ��ֵ �����뵽 func[idx] = {#func + 1, "accept", fname, f}
	env.accept = func_id(func, "accept")
	-- ֮����env.response ��ֵ �����뵽func[idx] = {#func + 1, "response", fname, f}
	env.response = func_id(func, "response")

	-- ֮����G��Ӷ�����������뵽func[]
	local function init_system(t, name, f)
		local index = system[name] -- id
		if index then
			-- ��ϵͳ����:"init"��"exit"��"hotfix", "profile" ֮һ
			if type(f) ~= "function" then
				error (string.format("%s must be a function", name))
			end
			func[index][4] = f	-- [1] id, [2] group, [3] name, [4] f��ǰ��3��֮ǰ���Ѿ�������
		else
			temp_global[name] = f -- ������ϵͳ���������ӵ�func����
		end
	end

	local pattern

	local path = assert(skynet.getenv "snax" , "please set snax in config file")
	mainfunc, pattern = loader(path, name, G)

	setmetatable(G,	{ __index = env , __newindex = init_system })
	local ok, err = xpcall(mainfunc, debug.traceback)	-- ���ʱ��֮ǰload���õ�__newindex������system��response��accept������Ч
	setmetatable(G, nil) -- ��env��_newindex�Ͽ���ϵ����Ϊ__newindex���ù��󣬶������ŵ�func��ȥ��
	assert(ok,err)

	-- ���ڲ���func�еĶ������ŵ�G����
	for k,v in pairs(temp_global) do
		G[k] = v
	end

	return func, pattern
end
