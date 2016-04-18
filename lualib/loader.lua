-- Ĭ��snlua����ִ�еĵ�һ���ű�
local args = {}
for word in string.gmatch(..., "%S+") do
	table.insert(args, word)
end

-- LUA_SERVICE  "./service/?.lua"
-- LUA_PATH		"./lualib/?.lua;./lualib/?/init.lua"
-- LUA_CPATH	"./luaclib/?.so"
-- LUA_PRELOAD	"preload"
-- ����4��ȫ�ֱ�������service_snlua�ж���

SERVICE_NAME = args[1]	-- ȫ�ֱ���

local main, pattern

-- ����ָ��ģʽ������û��ƥ����ļ����о�loadfile
local err = {}
for pat in string.gmatch(LUA_SERVICE, "([^;]+);*") do	-- ����;�ָ���ַ�������
	local filename = string.gsub(pat, "?", SERVICE_NAME)
	local f, msg = loadfile(filename)	-- ����ж�Ӧ�Ľű�������Ϊservice main �ű�
	if not f then
		table.insert(err, msg)
	else
		pattern = pat	-- "./service/?.lua"
		main = f
		break
	end
end

if not main then
	error(table.concat(err, "\n"))
end

-- ����ȫ�ֱ�������nil�����ýű�����·��package.path��clib����·��package.cpath
LUA_SERVICE = nil
package.path , LUA_PATH = LUA_PATH
package.cpath , LUA_CPATH = LUA_CPATH

local service_path = string.match(pattern, "(.*/)[^/?]+$")	-- ���ؽű����ڵ�Ŀ¼

if service_path then
	-- ˵�����service�е�����Ŀ¼������./service/?/
	service_path = string.gsub(service_path, "?", args[1])
	package.path = service_path .. "?.lua;" .. package.path	-- ����path�б�
	SERVICE_PATH = service_path
else
	local p = string.match(pattern, "(.*/).+$")				-- ��������./service/?.lua������./service/
	SERVICE_PATH = p
end

if LUA_PRELOAD then
	local f = assert(loadfile(LUA_PRELOAD))
	f(table.unpack(args))
	LUA_PRELOAD = nil	-- �ͷ�
end

main(select(2, table.unpack(args)))
