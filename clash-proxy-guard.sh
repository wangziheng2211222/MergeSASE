#!/bin/bash
CLASH_HOST="127.0.0.1"
CLASH_PORT="7897"

# ---- 公司域名 ----
COMPANY_DOMAINS="*.cds8.cn *.limayao.com"

# ---- 确保系统代理和绕过列表设置 ----
while IFS= read -r service; do
    [ -z "$service" ] && continue
    case "$service" in \**) continue ;; esac
    networksetup -setwebproxy "$service" "$CLASH_HOST" "$CLASH_PORT" 2>/dev/null
    networksetup -setsecurewebproxy "$service" "$CLASH_HOST" "$CLASH_PORT" 2>/dev/null
    networksetup -setsocksfirewallproxy "$service" "$CLASH_HOST" "$CLASH_PORT" 2>/dev/null
    networksetup -setproxybypassdomains "$service" \
        "127.0.0.1" "localhost" "*.local" "169.254.0.0/16" \
        "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "197.19.0.0/16" \
        "cds8.cn" "*.cds8.cn" "limayao.com" "*.limayao.com" 2>/dev/null
done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)

# ---- Chrome 策略: 强制使用代理+绕过公司域名 ----
CHROME_PLIST="$HOME/Library/Preferences/com.google.Chrome.plist"
defaults write "$CHROME_PLIST" ProxySettings -dict \
    ProxyMode "fixed_servers" \
    ProxyServer "127.0.0.1:7897" \
    ProxyBypassList "*.cds8.cn;*.limayao.com;10.0.0.0/8;172.16.0.0/12;192.168.0.0/16;197.19.0.0/16;127.0.0.1;localhost;*.local"
