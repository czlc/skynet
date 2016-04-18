local skynet = require "skynet"

local harbor = {}

-- ע��һ��ȫ�����֡���� handle Ϊ�գ���ע���Լ�
function harbor.globalname(name, handle)
	handle = handle or skynet.self()
	skynet.send(".cslave", "lua", "REGISTER", name, handle)
end

-- ����������ѯȫ�����ֻ򱾵����ֶ�Ӧ�ķ����ַ������һ���������á�
function harbor.queryname(name)
	return skynet.call(".cslave", "lua", "QUERYNAME", name)
end

-- �������һ�� slave �Ƿ�Ͽ������ harbor id ��Ӧ�� slave ��������� api ���������� slave �Ͽ�ʱ�������̷���
function harbor.link(id)
	skynet.call(".cslave", "lua", "LINK", id)
end

--  �� harbor.link �෴����� harbor id ��Ӧ�� slave û�����ӣ���� api ��������һֱ�����������ŷ���
function harbor.connect(id)
	skynet.call(".cslave", "lua", "CONNECT", id)
end

-- ���MASTER�Ƿ�Ͽ�
function harbor.linkmaster()
	skynet.call(".cslave", "lua", "LINKMASTER")
end

return harbor
