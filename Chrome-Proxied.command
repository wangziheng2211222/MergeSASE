#!/bin/bash
# 双击启动 Chrome，同时访问外网和公司内网
killall "Google Chrome" 2>/dev/null
sleep 1
open -a "Google Chrome" --args \
    --proxy-server="http://127.0.0.1:7897" \
    --proxy-bypass-list="*.cds8.cn;*.limayao.com;ai-platform-cicada-llm-api.limayao.com;10.0.0.0/8;172.16.0.0/12;192.168.0.0/16;197.19.0.0/16;127.0.0.1;localhost;*.local" \
    --disable-quic
echo "Chrome 已启动: YouTube ✅ | 公司内网 ✅"
