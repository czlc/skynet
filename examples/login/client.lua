package.cpath = "luaclib/?.so"

local socket = require "clientsocket"
local crypt = require "crypt"

if _VERSION ~= "Lua 5.3" then
	error "Use lua 5.3"
end

local fd = assert(socket.connect("127.0.0.1", 8001)) -- 连接loginserver

local function writeline(fd, text)
	socket.send(fd, text .. "\n")
end

local function unpack_line(text)
	local from = text:find("\n", 1, true)
	if from then
		return text:sub(1, from-1), text:sub(from+1)
	end
	return nil, text
end

local last = ""

local function unpack_f(f)
	local function try_recv(fd, last)
		local result
		result, last = f(last)
		if result then
			return result, last
		end
		local r = socket.recv(fd)
		if not r then
			return nil, last
		end
		if r == "" then
			error "Server closed"
		end
		return f(last .. r)
	end

	return function()
		while true do
			local result
			result, last = try_recv(fd, last)
			if result then
				return result
			end
			socket.usleep(100)
		end
	end
end

local readline = unpack_f(unpack_line)

local challenge = crypt.base64decode(readline())

local clientkey = crypt.randomkey()
-- Protocol:2. Client->Server : base64(8bytes handshake client key)
writeline(fd, crypt.base64encode(crypt.dhexchange(clientkey))) -- 即使截获这个值，也反推不出clientkey(计算对数相当困难)，从而也无法计算secret
-- Protocol:5. Server/Client secret := DH-Secret(client key/server key)
local secret = crypt.dhsecret(crypt.base64decode(readline()), clientkey)

print("sceret is ", crypt.hexencode(secret))

-- Protocol:6. Client->Server : base64(HMAC(challenge, secret))
local hmac = crypt.hmac64(challenge, secret)
writeline(fd, crypt.base64encode(hmac)) -- login step 3:C 和 L 交换后续通讯用的密钥 secret ，并立刻验证。

-- login step 1: C 向 A 发起一次认证请求 (A 通常是第三方认证平台)，获得一个 token 。这个 token 里通常包含有用户名称以及用于校验用户合法性的其它信息。
local token = {
	server = "sample",
	user = "hello",
	pass = "password",
}

local function encode_token(token)
	return string.format("%s@%s:%s",
		crypt.base64encode(token.user),
		crypt.base64encode(token.server),
		crypt.base64encode(token.pass))
end

-- Protocl:7. Client->Server : DES(secret, base64(token))
local etoken = crypt.desencode(secret, encode_token(token))
local b = crypt.base64encode(etoken)
writeline(fd, crypt.base64encode(etoken)) -- login step 2:C 将他希望登陆的登陆点 G1 (或其它登陆点，可由系统设计的负载均衡器来选择）以及 step 1 获得的 token 一起发送给 L 。

local result = readline()
print(result)
local code = tonumber(string.sub(result, 1, 3))
assert(code == 200)
socket.close(fd)

local subid = crypt.base64decode(string.sub(result, 5))

print("login ok, subid=", subid)

----- connect to game server

local function send_request(v, session)
	local size = #v + 4
	local package = string.pack(">I2", size)..v..string.pack(">I4", session)
	socket.send(fd, package)
	return v, session
end

local function recv_response(v)
	local size = #v - 5
	local content, ok, session = string.unpack("c"..tostring(size).."B>I4", v)
	return ok ~=0 , content, session
end

local function unpack_package(text)
	local size = #text
	if size < 2 then
		return nil, text
	end
	local s = text:byte(1) * 256 + text:byte(2)
	if size < s+2 then
		return nil, text
	end

	return text:sub(3,2+s), text:sub(3+s)
end

local readpackage = unpack_f(unpack_package)

local function send_package(fd, pack)
	local package = string.pack(">s2", pack)
	socket.send(fd, package)
end

local text = "echo"
local index = 1
-- login step 9:C 得到 L 的确认后，断开和 L 的连接。然后连接 G1 ，并利用 username 和 secret 进行握手。
print("connect")
fd = assert(socket.connect("127.0.0.1", 8888))
last = ""

local handshake = string.format("%s@%s#%s:%d", crypt.base64encode(token.user), crypt.base64encode(token.server),crypt.base64encode(subid) , index)
local hmac = crypt.hmac64(crypt.hashkey(handshake), secret)


send_package(fd, handshake .. ":" .. crypt.base64encode(hmac))

print(readpackage())
print("===>",send_request(text,0))
-- don't recv response
-- print("<===",recv_response(readpackage()))

print("disconnect")
socket.close(fd)

index = index + 1

print("connect again")
fd = assert(socket.connect("127.0.0.1", 8888))
last = ""

local handshake = string.format("%s@%s#%s:%d", crypt.base64encode(token.user), crypt.base64encode(token.server),crypt.base64encode(subid) , index)
local hmac = crypt.hmac64(crypt.hashkey(handshake), secret)

send_package(fd, handshake .. ":" .. crypt.base64encode(hmac))

print(readpackage())
print("===>",send_request("fake",0))	-- request again (use last session 0, so the request message is fake)
print("===>",send_request("again",1))	-- request again (use new session)
print("<===",recv_response(readpackage()))
print("<===",recv_response(readpackage()))


print("disconnect")
socket.close(fd)

