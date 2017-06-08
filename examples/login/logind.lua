local login = require "snax.loginserver"
local crypt = require "skynet.crypt"
local skynet = require "skynet"

local server = {
	host = "127.0.0.1",
	port = 8001,
	multilogin = false,	-- disallow multilogin
	name = "login_master",	-- 不要和 skynet 其它服务重名
}

local server_list = {}
local user_online = {}
local user_login = {}

-- 如果验证通过，需要返回用户希望进入的登陆点（登陆点可以是包含在 token 内由用户自行决定,也可以在这里实现一个负载均衡器来选择）；以及用户名。
-- login step 4.1: L 校验token 的合法性（此处有可能需要 L 和 A 做一次确认）。
-- slave
function server.auth_handler(token)
	-- the token is base64(user)@base64(server):base64(password)
	local user, server, password = token:match("([^@]+)@([^:]+):(.+)")
	user = crypt.base64decode(user)
	server = crypt.base64decode(server)
	password = crypt.base64decode(password)
	assert(password == "password", "Invalid password")
	return server, user
end

-- 处理当用户已经验证通过后，该如何通知具体的登陆点（server ）
-- 框架会交给你用户名（uid）和已经安全交换到的通讯密钥。你需要把它们交给登陆点，并得到确认（等待登陆点准备好后）才可以返回。
-- master
function server.login_handler(server, uid, secret)
	print(string.format("%s@%s is login, secret is %s", uid, server, crypt.hexencode(secret)))
	local gameserver = assert(server_list[server], "Unknown server") -- login step 4.2: L 校验登陆点是否存在
	-- only one can login, because disallow multilogin
	local last = user_online[uid] -- login step 5:（可选步骤）L 检查 C 是否已经登陆，如果已经登陆，向它所在的登陆点（可以是一个，也可以是多个）发送信号，等待登陆点确认。通常这个步骤可以将已登陆的用户登出。
	if last then
		skynet.call(last.address, "lua", "kick", uid, last.subid)
	end
	if user_online[uid] then
		error(string.format("user %s is already online", uid))
	end

	-- login step 6:L 向 G1 发送用户 C 将登陆的请求，并同时发送 secret 。
	local subid = tostring(skynet.call(gameserver, "lua", "login", uid, secret))
	user_online[uid] = { address = gameserver, subid = subid , server = server}
	return subid
end

local CMD = {}

-- 动态注册新的登陆点
function CMD.register_gate(server, address)
	server_list[server] = address
end

function CMD.logout(uid, subid)
	local u = user_online[uid]
	if u then
		print(string.format("%s@%s is logout", uid, u.server))
		user_online[uid] = nil
	end
end

-- master
function server.command_handler(command, ...)
	local f = assert(CMD[command])
	return f(...)
end

login(server)
