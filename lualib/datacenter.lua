-- https://github.com/cloudwu/skynet/wiki/DataCenter
-- ������Ҫ��ڵ�ͨѶʱ����ȻֻҪ���������ڵ�ĵ�ַ���Ϳ��Է�����Ϣ������ַ��λ�ã�ȴ��һ�����⡣
-- ����һ��ȫ���繲���ע���
local skynet = require "skynet"

local datacenter = {}

-- �� key1.key2 ��һ��ֵ����� api ������Ҫһ�������������������������������������һ����֧��
function datacenter.get(...)
	return skynet.call("DATACENTER", "lua", "QUERY", ...)
end

-- ������ key1.key2 ����һ��ֵ value ����� api ������Ҫ����������û���ر��������ṹ�Ĳ㼶����
function datacenter.set(...)
	return skynet.call("DATACENTER", "lua", "UPDATE", ...)
end

--ͬ get �������������ȡ�ķ�֧Ϊ nil ʱ�����������������ֱ�����˸��������֧�ŷ���
-- wait ����������һ��Ҷ�ڵ㣬���ܵȴ�һ����֧��
function datacenter.wait(...)
	return skynet.call("DATACENTER", "lua", "WAIT", ...)
end

return datacenter

