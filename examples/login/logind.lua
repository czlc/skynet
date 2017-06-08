local login = require "snax.loginserver"
local crypt = require "skynet.crypt"
local skynet = require "skynet"

local server = {
	host = "127.0.0.1",
	port = 8001,
	multilogin = false,	-- disallow multilogin
	name = "login_master",	-- ��Ҫ�� skynet ������������
}

local server_list = {}
local user_online = {}
local user_login = {}

-- �����֤ͨ������Ҫ�����û�ϣ������ĵ�½�㣨��½������ǰ����� token �����û����о���,Ҳ����������ʵ��һ�����ؾ�������ѡ�񣩣��Լ��û�����
-- login step 4.1: L У��token �ĺϷ��ԣ��˴��п�����Ҫ L �� A ��һ��ȷ�ϣ���
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

-- �����û��Ѿ���֤ͨ���󣬸����֪ͨ����ĵ�½�㣨server ��
-- ��ܻύ�����û�����uid�����Ѿ���ȫ��������ͨѶ��Կ������Ҫ�����ǽ�����½�㣬���õ�ȷ�ϣ��ȴ���½��׼���ú󣩲ſ��Է��ء�
-- master
function server.login_handler(server, uid, secret)
	print(string.format("%s@%s is login, secret is %s", uid, server, crypt.hexencode(secret)))
	local gameserver = assert(server_list[server], "Unknown server") -- login step 4.2: L У���½���Ƿ����
	-- only one can login, because disallow multilogin
	local last = user_online[uid] -- login step 5:����ѡ���裩L ��� C �Ƿ��Ѿ���½������Ѿ���½���������ڵĵ�½�㣨������һ����Ҳ�����Ƕ���������źţ��ȴ���½��ȷ�ϡ�ͨ�����������Խ��ѵ�½���û��ǳ���
	if last then
		skynet.call(last.address, "lua", "kick", uid, last.subid)
	end
	if user_online[uid] then
		error(string.format("user %s is already online", uid))
	end

	-- login step 6:L �� G1 �����û� C ����½�����󣬲�ͬʱ���� secret ��
	local subid = tostring(skynet.call(gameserver, "lua", "login", uid, secret))
	user_online[uid] = { address = gameserver, subid = subid , server = server}
	return subid
end

local CMD = {}

-- ��̬ע���µĵ�½��
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
