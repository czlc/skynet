local skynet = require "skynet"

-- �������ܣ�����nameָ����snax service�ű��������ű��еĽӿڰ�����ŵ�func�в�����
-- func[id] = {id, group, fname, function}
-- ����group������"accept"��"response"��"system"
-- ����ȫ�ֺ���init, exit, hotfix��accept.xxx��response.xxx
-- ����ȫ�ֺ������ص�G����
return function (name , G, loader)
	loader = loader or loadfile
	local mainfunc

	-- ����һ��table�������table��Ӻ�����ʱ��Ὣ����ĺ���ת��
	-- ��ӽ������func ��
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
		-- 
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

	local system = { "init", "exit", "hotfix" }

	do
		for k, v in ipairs(system) do
			system[v] = k
			func[k] = { k , "system", v }
		end
	end

	-- ֮����env.accept��ӵ�Ԫ�ؽ����뵽func[idx] = {#func + 1, "accept", fname, f}
	env.accept = func_id(func, "accept")
	-- ֮����env.response��ӵ�Ԫ�ؽ����뵽func[idx] = {#func + 1, "response", fname, f}
	env.response = func_id(func, "response")

	-- ֮����G��Ӷ�����������뵽func[]
	local function init_system(t, name, f)
		local index = system[name] -- id
		if index then
			-- ��ϵͳ����:"init"��"exit"��"hotfix"֮һ
			if type(f) ~= "function" then
				error (string.format("%s must be a function", name))
			end

			func[index][4] = f	-- [1] id, [2] group, [3] name, [4] f��ǰ��3��֮ǰ���Ѿ�������
		else
			temp_global[name] = f -- ������ϵͳ���������ӵ�func����
		end
	end

	local pattern

	do
		-- snax ����������ַ
		local path = assert(skynet.getenv "snax" , "please set snax in config file")

		local errlist = {}

		for pat in string.gmatch(path,"[^;]+") do
			local filename = string.gsub(pat, "?", name)
			local f , err = loader(filename, "bt", G)	-- ֻ��load��û��ִ��
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
	local ok, err = pcall(mainfunc)	-- ���ʱ��֮ǰload���õ�__newindex������system��response��accept������Ч
	setmetatable(G, nil) -- ��env��_newindex�Ͽ���ϵ����Ϊ__newindex���ù��󣬶������ŵ�func��ȥ��
	assert(ok,err)

	-- ���ڲ���func�еĶ������ŵ�G����
	for k,v in pairs(temp_global) do
		G[k] = v
	end

	return func, pattern
end
