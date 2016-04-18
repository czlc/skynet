-- 默认snlua服务执行的第一个脚本
local args = {}
for word in string.gmatch(..., "%S+") do
	table.insert(args, word)
end

-- LUA_SERVICE  "./service/?.lua"
-- LUA_PATH		"./lualib/?.lua;./lualib/?/init.lua"
-- LUA_CPATH	"./luaclib/?.so"
-- LUA_PRELOAD	"preload"
-- 以上4个全局变量均在service_snlua中定义

SERVICE_NAME = args[1]	-- 全局变量

local main, pattern

-- 遍历指定模式串看有没有匹配的文件，有就loadfile
local err = {}
for pat in string.gmatch(LUA_SERVICE, "([^;]+);*") do	-- 遍历;分割的字符串数组
	local filename = string.gsub(pat, "?", SERVICE_NAME)
	local f, msg = loadfile(filename)	-- 如果有对应的脚本，则其为service main 脚本
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

-- 三个全局遍历都置nil，设置脚本查找路径package.path，clib查找路径package.cpath
LUA_SERVICE = nil
package.path , LUA_PATH = LUA_PATH
package.cpath , LUA_CPATH = LUA_CPATH

local service_path = string.match(pattern, "(.*/)[^/?]+$")	-- 返回脚本所在的目录

if service_path then
	-- 说明这个service有单独的目录，比如./service/?/
	service_path = string.gsub(service_path, "?", args[1])
	package.path = service_path .. "?.lua;" .. package.path	-- 加入path列表
	SERVICE_PATH = service_path
else
	local p = string.match(pattern, "(.*/).+$")				-- 处理类似./service/?.lua，返回./service/
	SERVICE_PATH = p
end

if LUA_PRELOAD then
	local f = assert(loadfile(LUA_PRELOAD))
	f(table.unpack(args))
	LUA_PRELOAD = nil	-- 释放
end

main(select(2, table.unpack(args)))
