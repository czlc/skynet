-- ������񣬱�����ֱ�ӷ���clusterd���Ҵ�node��address�ģ�ͨ���������������
-- ���ù���node��address��Ҳ��clusterdҲ���ù��ģ�������ʱ��ط���һ��
local skynet = require "skynet"
local cluster = require "cluster"
require "skynet.manager"	-- inject skynet.forward_type

local node, address = ...

skynet.register_protocol {
	name = "system",
	id = skynet.PTYPE_SYSTEM,
	unpack = function (...) return ... end,	-- ת������Ҫ������ɵ����߽��
}

local forward_map = {
	[skynet.PTYPE_SNAX] = skynet.PTYPE_SYSTEM,
	[skynet.PTYPE_LUA] = skynet.PTYPE_SYSTEM,
	[skynet.PTYPE_RESPONSE] = skynet.PTYPE_RESPONSE,	-- don't free response message����skynet.forward_type����Ϊreturn ����Ϣ��Ҫ����ת����������������еĶ�����ɾ��
}

skynet.forward_type( forward_map ,function()
	local clusterd = skynet.uniqueservice("clusterd")
	local n = tonumber(address)
	if n then
		address = n
	end
	-- ����system���͵���Ϣת��,��clusterd����ɾ��(Ĭ�ϲ���forward callback�����Զ�ɾ��)
	-- rawcall��������ȴ���Ӧ��RESPONSE��Ϣ�����Ժ���Ҫ�����Ա�֮�󷵻ظ�����"system"�������ߣ�����don't free response message
	skynet.dispatch("system", function (session, source, msg, sz)
		if session == 0 then
			skynet.send(clusterd, "lua", "push", node, address, msg, sz)
		else
			skynet.ret(skynet.rawcall(clusterd, "lua", skynet.pack("req", node, address, msg, sz)))
		end
	end)
end)
