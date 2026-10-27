#!/bin/bash
# Emergency repair for old Clash + SASE setups.
# Double-click this file on the affected Mac after SASE/OpenVPN and Clash are running.

set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

LOG_FILE="$HOME/Desktop/limayao-network-repair-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$HOME/Desktop"
exec > >(tee -a "$LOG_FILE") 2>&1

RED="$(printf '\033[0;31m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
NC="$(printf '\033[0m')"

log() { echo "${GREEN}[+]${NC} $*"; }
warn() { echo "${YELLOW}[!]${NC} $*"; }
err() { echo "${RED}[x]${NC} $*"; }

CHECK_URL="https://ai.limayao.com/developer"
CLASH_HOST="127.0.0.1"
CORP_DNS_SERVERS=("10.25.1.1")
COMPANY_DOMAINS=("cds8.cn" "limayao.com")
DIRECT_HOSTS=(
    "ai.limayao.com"
    "new-api.limayao.com"
    "ai-platform-cicada-llm-api.limayao.com"
    "new-api.cds8.cn"
)
STATIC_BYPASS=(
    "127.0.0.1"
    "localhost"
    "*.local"
    "169.254.0.0/16"
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "197.19.0.0/16"
    "198.18.0.0/16"
)
INTERNAL_RANGES=("197.19.0.0/16" "10.1.0.0/16" "10.66.0.0/16")

echo ""
echo "============================================================"
echo "  limayao 开发者后台网络应急修复"
echo "============================================================"
echo "日志会保存到: $LOG_FILE"
echo ""

add_unique_range() {
    local value="$1"
    local item
    [ -z "$value" ] && return
    for item in "${INTERNAL_RANGES[@]}"; do
        [ "$item" = "$value" ] && return
    done
    INTERNAL_RANGES+=("$value")
}

is_ipv4() {
    echo "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

is_fake_ip() {
    case "$1" in
        198.18.*|198.19.*) return 0 ;;
        *) return 1 ;;
    esac
}

route_range_for_ip() {
    local ip="$1"
    local a b c d
    IFS=. read -r a b c d <<EOF_IP
$ip
EOF_IP
    [ -z "${a:-}" ] || [ -z "${b:-}" ] && return 1
    echo "${a}.${b}.0.0/16"
}

netmask_for_prefix() {
    case "$1" in
        8) echo "255.0.0.0" ;;
        12) echo "255.240.0.0" ;;
        16) echo "255.255.0.0" ;;
        20) echo "255.255.240.0" ;;
        24) echo "255.255.255.0" ;;
        32) echo "255.255.255.255" ;;
        *) echo "" ;;
    esac
}

detect_clash_port() {
    local port
    port=$(scutil --proxy 2>/dev/null | awk '/HTTPPort/{print $3; exit}')
    if [ -n "$port" ]; then
        echo "$port"
        return
    fi

    local configs=(
        "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/config.yaml"
        "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml"
        "$HOME/.config/clash/config.yaml"
        "$HOME/.config/mihomo/config.yaml"
    )
    local file
    for file in "${configs[@]}"; do
        [ -f "$file" ] || continue
        port=$(grep -E '^[[:space:]]*(mixed-port|mixed_port|port):' "$file" 2>/dev/null | grep -Eo '[0-9]+' | head -1)
        if [ -n "$port" ]; then
            echo "$port"
            return
        fi
    done

    port=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk '/mihomo|clash|Clash/ && /127\.0\.0\.1:/ {split($9,a,":"); print a[2]; exit}')
    [ -n "$port" ] && echo "$port" || echo "7897"
}

resolve_real_ipv4() {
    local host="$1"
    local ip server output

    output=$(dig +short +time=2 +tries=1 "$host" A 2>/dev/null)
    for ip in $output; do
        if is_ipv4 "$ip" && ! is_fake_ip "$ip"; then
            echo "$ip"
            return 0
        fi
    done

    for server in "${CORP_DNS_SERVERS[@]}"; do
        output=$(dig @"$server" +short +time=2 +tries=1 "$host" A 2>/dev/null)
        for ip in $output; do
            if is_ipv4 "$ip" && ! is_fake_ip "$ip"; then
                echo "$ip"
                return 0
            fi
        done
    done
    return 1
}

route_iface_for_ip() {
    route -n get "$1" 2>/dev/null | awk '/interface:/{print $2; exit}'
}

is_vpn_iface() {
    case "$1" in
        utun*|tun*|tap*|ppp*) return 0 ;;
        *) return 1 ;;
    esac
}

detect_vpn_iface() {
    local iface ip host
    iface=$(route_iface_for_ip "10.25.1.1")
    if is_vpn_iface "$iface"; then
        echo "$iface"
        return 0
    fi

    for host in "${DIRECT_HOSTS[@]}"; do
        ip=$(resolve_real_ipv4 "$host" || true)
        [ -n "$ip" ] || continue
        iface=$(route_iface_for_ip "$ip")
        if is_vpn_iface "$iface"; then
            echo "$iface"
            return 0
        fi
    done

    netstat -rn -f inet 2>/dev/null | awk '$NF ~ /^(utun|tun|tap|ppp)/ && $1 !~ /^198\.18/ {print $NF; exit}'
}

quote_items() {
    local item
    for item in "$@"; do
        printf '    "%s"\n' "$item"
    done
}

join_by_semicolon() {
    local first=1 item out=""
    for item in "$@"; do
        if [ "$first" -eq 1 ]; then
            out="$item"
            first=0
        else
            out="${out};${item}"
        fi
    done
    echo "$out"
}

join_by_comma() {
    local first=1 item out=""
    for item in "$@"; do
        if [ "$first" -eq 1 ]; then
            out="$item"
            first=0
        else
            out="${out},${item}"
        fi
    done
    echo "$out"
}

corp_dns_policy_value() {
    if dig @10.25.1.1 +short +time=2 +tries=1 ai.limayao.com A 2>/dev/null | grep -Eq '^[0-9]+\.'; then
        echo "'10.25.1.1'"
    else
        echo "system"
    fi
}

write_clash_merge_config() {
    local dns_policy="$1"
    local route_lines filter_lines policy_lines merge_content dir path
    route_lines=$(for r in "${INTERNAL_RANGES[@]}"; do printf "    - '%s'\n" "$r"; done)
    filter_lines=$(cat <<'EOF_FILTER'
    - '+.cds8.cn'
    - '+.limayao.com'
    - 'ai.limayao.com'
    - 'new-api.limayao.com'
    - 'new-api.cds8.cn'
    - 'ai-platform-cicada-llm-api.limayao.com'
EOF_FILTER
)
    policy_lines=$(cat <<EOF_POLICY
    '+.cds8.cn': $dns_policy
    '+.limayao.com': $dns_policy
    'ai.limayao.com': $dns_policy
    'new-api.limayao.com': $dns_policy
    'new-api.cds8.cn': $dns_policy
    'ai-platform-cicada-llm-api.limayao.com': $dns_policy
EOF_POLICY
)

    merge_content=$(cat <<EOF_MERGE
# Generated by limayao-developer-emergency-fix.command
profile:
  store-selected: true

dns:
  use-system-hosts: false
  fake-ip-filter-mode: blacklist
  fake-ip-filter:
$filter_lines
  nameserver-policy:
$policy_lines

tun:
  enable: true
  stack: system
  route-exclude-address:
$route_lines
  route-exclude:
$route_lines
EOF_MERGE
)

    local paths=(
        "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/merge.yaml"
        "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles/merge.yaml"
    )
    for path in "${paths[@]}"; do
        dir=$(dirname "$path")
        if [ -d "$dir" ]; then
            printf "%s\n" "$merge_content" > "$path"
            log "已写入 Clash merge 配置: $path"
        fi
    done
}

insert_after_section_if_missing() {
    local file="$1"
    local section="$2"
    local line="$3"
    grep -Fq "$line" "$file" 2>/dev/null && return
    awk -v section="$section" -v newline="$line" '
        $0 ~ section && done == 0 { print; print newline; done = 1; next }
        { print }
    ' "$file" > "$file.tmp.$$" && mv "$file.tmp.$$" "$file"
}

patch_running_clash_configs() {
    local dns_policy="$1"
    local file backup rule cidr range
    local files=(
        "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml"
        "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge-check.yaml"
        "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/config.yaml"
    )

    for file in "${files[@]}"; do
        [ -f "$file" ] || continue
        backup="${file}.limayao-repair.$(date +%Y%m%d%H%M%S).bak"
        cp "$file" "$backup" 2>/dev/null || true

        if grep -q "fake-ip-filter:" "$file"; then
            insert_after_section_if_missing "$file" "fake-ip-filter:" "  - '+.limayao.com'"
            insert_after_section_if_missing "$file" "fake-ip-filter:" "  - '+.cds8.cn'"
            insert_after_section_if_missing "$file" "fake-ip-filter:" "  - 'ai.limayao.com'"
            insert_after_section_if_missing "$file" "fake-ip-filter:" "  - 'new-api.limayao.com'"
        elif grep -q "fake-ip-range:" "$file"; then
            awk '
                /fake-ip-range:/ && done == 0 {
                    print
                    print "  fake-ip-filter-mode: blacklist"
                    print "  fake-ip-filter:"
                    print "  - '\''+.limayao.com'\''"
                    print "  - '\''+.cds8.cn'\''"
                    print "  - '\''ai.limayao.com'\''"
                    print "  - '\''new-api.limayao.com'\''"
                    done = 1
                    next
                }
                { print }
            ' "$file" > "$file.tmp.$$" && mv "$file.tmp.$$" "$file"
        fi

        if grep -q "nameserver-policy: {}" "$file"; then
            perl -0pi -e "s/nameserver-policy: \\{\\}/nameserver-policy:\\n    '+.limayao.com': $dns_policy\\n    '+.cds8.cn': $dns_policy\\n    'ai.limayao.com': $dns_policy/g" "$file" 2>/dev/null || true
        elif grep -q "nameserver-policy:" "$file"; then
            insert_after_section_if_missing "$file" "nameserver-policy:" "    '+.limayao.com': $dns_policy"
            insert_after_section_if_missing "$file" "nameserver-policy:" "    '+.cds8.cn': $dns_policy"
            insert_after_section_if_missing "$file" "nameserver-policy:" "    'ai.limayao.com': $dns_policy"
        fi

        if grep -q "^rules:" "$file"; then
            for rule in "DOMAIN-SUFFIX,limayao.com,DIRECT" "DOMAIN-SUFFIX,cds8.cn,DIRECT"; do
                grep -Fq "$rule" "$file" || insert_after_section_if_missing "$file" "^rules:" "- $rule"
            done
            for range in "${INTERNAL_RANGES[@]}"; do
                cidr="IP-CIDR,$range,DIRECT,no-resolve"
                grep -Fq "$cidr" "$file" || insert_after_section_if_missing "$file" "^rules:" "- $cidr"
            done
        fi

        log "已修补 Clash 运行配置: $(basename "$file")，备份: $backup"
    done
}

reload_clash() {
    local config api_addr secret auth_part http_code config_path file
    kill -HUP $(pgrep -f "mihomo|clash") 2>/dev/null && log "已发送 SIGHUP 给 Clash/mihomo" || true

    api_addr="127.0.0.1:9097"
    secret=""
    for file in \
        "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/config.yaml" \
        "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml"; do
        [ -f "$file" ] || continue
        config_path="$file"
        config=$(cat "$file")
        api_addr=$(printf "%s\n" "$config" | awk '/^[[:space:]]*external-controller:/{sub(/^[[:space:]]*external-controller:[[:space:]]*/, ""); gsub(/^[ \t"'"'"']+|[ \t"'"'"']+$/, ""); print; exit}')
        [ -n "$api_addr" ] || api_addr="127.0.0.1:9097"
        secret=$(printf "%s\n" "$config" | awk -F: '/^[[:space:]]*secret:/{sub(/^[^:]*:/,""); gsub(/^[ \t"'"'"']+|[ \t"'"'"']+$/, ""); print; exit}')
        break
    done

    auth_part=()
    if [ -n "$secret" ]; then
        auth_part=(-H "Authorization: Bearer $secret")
    fi
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "http://${api_addr}/configs?force=true" -H "Content-Type: application/json" "${auth_part[@]}" -d "{\"path\":\"${config_path:-}\"}" 2>/dev/null)
    if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
        log "Clash API 重载成功"
    else
        warn "未确认 Clash API 热重载成功（HTTP $http_code）。如仍不通，请在 Clash Verge 里手动 Reload 一次。"
    fi
}

set_system_proxy_and_env() {
    local port="$1"
    local bypass=("${STATIC_BYPASS[@]}")
    local domain range service no_proxy proxy_url

    for domain in "${COMPANY_DOMAINS[@]}"; do
        bypass+=("$domain" "*.$domain")
    done
    bypass+=("${DIRECT_HOSTS[@]}")
    for range in "${INTERNAL_RANGES[@]}"; do
        bypass+=("$range")
    done

    while IFS= read -r service; do
        [ -z "$service" ] && continue
        case "$service" in \**) continue ;; esac
        networksetup -setwebproxy "$service" "$CLASH_HOST" "$port" 2>/dev/null || true
        networksetup -setsecurewebproxy "$service" "$CLASH_HOST" "$port" 2>/dev/null || true
        networksetup -setsocksfirewallproxy "$service" "$CLASH_HOST" "$port" 2>/dev/null || true
        networksetup -setproxybypassdomains "$service" "${bypass[@]}" 2>/dev/null || true
        log "已设置网络服务代理和绕过: $service"
    done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)

    proxy_url="http://${CLASH_HOST}:${port}"
    no_proxy=$(join_by_comma "localhost" "127.0.0.1" "::1" ".local" "${INTERNAL_RANGES[@]}" "cds8.cn" ".cds8.cn" "*.cds8.cn" "limayao.com" ".limayao.com" "*.limayao.com" "${DIRECT_HOSTS[@]}")
    for key in HTTP_PROXY http_proxy HTTPS_PROXY https_proxy; do
        launchctl setenv "$key" "$proxy_url" 2>/dev/null || true
    done
    for key in ALL_PROXY all_proxy; do
        launchctl unsetenv "$key" 2>/dev/null || true
    done
    for key in NO_PROXY no_proxy; do
        launchctl setenv "$key" "$no_proxy" 2>/dev/null || true
    done
    log "已设置应用代理环境，并清理 ALL_PROXY"
}

write_guard() {
    local port="$1"
    local guard_script="$HOME/.local/bin/clash-proxy-guard.sh"
    local plist_path="$HOME/Library/LaunchAgents/com.clash.proxyguard.plist"
    local bypass_items=("${STATIC_BYPASS[@]}" "${INTERNAL_RANGES[@]}" "cds8.cn" "*.cds8.cn" "limayao.com" "*.limayao.com" "${DIRECT_HOSTS[@]}")
    local bypass_lines

    mkdir -p "$(dirname "$guard_script")" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    bypass_lines=$(quote_items "${bypass_items[@]}")

    cat > "$guard_script" <<EOF_GUARD
#!/bin/bash
CLASH_HOST="$CLASH_HOST"
CLASH_PORT="$port"
BYPASS=(
$bypass_lines
)
while IFS= read -r service; do
    [ -z "\$service" ] && continue
    case "\$service" in \\**) continue ;; esac
    networksetup -setwebproxy "\$service" "\$CLASH_HOST" "\$CLASH_PORT" 2>/dev/null || true
    networksetup -setsecurewebproxy "\$service" "\$CLASH_HOST" "\$CLASH_PORT" 2>/dev/null || true
    networksetup -setsocksfirewallproxy "\$service" "\$CLASH_HOST" "\$CLASH_PORT" 2>/dev/null || true
    networksetup -setproxybypassdomains "\$service" "\${BYPASS[@]}" 2>/dev/null || true
done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)
EOF_GUARD
    chmod +x "$guard_script"

    cat > "$plist_path" <<EOF_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.clash.proxyguard</string>
    <key>ProgramArguments</key><array><string>$guard_script</string></array>
    <key>RunAtLoad</key><true/>
    <key>WatchPaths</key><array><string>/Library/Preferences/SystemConfiguration/preferences.plist</string></array>
    <key>ThrottleInterval</key><integer>2</integer>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/clash-proxy-guard.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/clash-proxy-guard.log</string>
</dict>
</plist>
EOF_PLIST
    launchctl unload "$plist_path" 2>/dev/null || true
    launchctl load "$plist_path" 2>/dev/null && log "网络守护已启动" || warn "网络守护加载失败，可忽略一次；当前修复已立即应用"
}

write_chrome_policy() {
    local port="$1"
    local bypass=("${STATIC_BYPASS[@]}" "${INTERNAL_RANGES[@]}" "cds8.cn" "*.cds8.cn" "limayao.com" "*.limayao.com" "${DIRECT_HOSTS[@]}")
    local bypass_str managed_dir policy_path
    bypass_str=$(join_by_semicolon "${bypass[@]}")
    managed_dir="$HOME/Library/Application Support/Google/Chrome/Managed"
    policy_path="$managed_dir/com.google.Chrome.plist"
    mkdir -p "$managed_dir"

    cat > "$policy_path" <<EOF_CHROME
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ProxySettings</key>
    <dict>
        <key>ProxyMode</key><string>fixed_servers</string>
        <key>ProxyServer</key><string>${CLASH_HOST}:${port}</string>
        <key>ProxyBypassList</key><string>${bypass_str}</string>
    </dict>
</dict>
</plist>
EOF_CHROME

    defaults write "$HOME/Library/Preferences/com.google.Chrome.plist" ProxySettings -dict \
        ProxyMode "fixed_servers" \
        ProxyServer "${CLASH_HOST}:${port}" \
        ProxyBypassList "$bypass_str" 2>/dev/null || true
    log "Chrome 代理策略已写入"
}

add_temp_routes_if_needed() {
    local vpn_if="$1"
    local host ip iface range net prefix mask

    if [ -z "$vpn_if" ] || ! is_vpn_iface "$vpn_if"; then
        warn "没有识别到公司 VPN 的 utun/tun/tap 接口；跳过临时路由修复。请先连接 SASE/OpenVPN。"
        return
    fi

    for host in "${DIRECT_HOSTS[@]}"; do
        ip=$(resolve_real_ipv4 "$host" || true)
        [ -n "$ip" ] || continue
        iface=$(route_iface_for_ip "$ip")
        if is_vpn_iface "$iface"; then
            log "$host -> $ip 已走 VPN 接口 $iface"
            continue
        fi

        range=$(route_range_for_ip "$ip" || true)
        [ -n "$range" ] || continue
        net="${range%/*}"
        prefix="${range#*/}"
        mask=$(netmask_for_prefix "$prefix")
        [ -n "$mask" ] || continue

        warn "$host -> $ip 当前走 ${iface:-未知接口}，尝试把 $range 临时指向 $vpn_if"
        sudo -v || {
            warn "没有获得管理员权限，无法添加临时路由"
            return
        }
        sudo route -n add -net "$net" -netmask "$mask" -interface "$vpn_if" 2>/dev/null \
            || sudo route -n change -net "$net" -netmask "$mask" -interface "$vpn_if" 2>/dev/null \
            || warn "临时路由 $range 添加失败"
    done
}

flush_dns_cache() {
    dscacheutil -flushcache 2>/dev/null || true
    sudo killall -HUP mDNSResponder 2>/dev/null || true
    log "已刷新 macOS DNS 缓存"
}

restart_chrome_prompt() {
    local port="$1"
    local bypass=("${STATIC_BYPASS[@]}" "${INTERNAL_RANGES[@]}" "cds8.cn" "*.cds8.cn" "limayao.com" "*.limayao.com" "${DIRECT_HOSTS[@]}")
    local bypass_str answer
    bypass_str=$(join_by_semicolon "${bypass[@]}")

    if pgrep -x "Google Chrome" >/dev/null 2>&1; then
        echo ""
        warn "检测到 Chrome 正在运行。Chrome 必须完全退出再打开，才能可靠套用新代理策略。"
        printf "现在自动退出并重新打开 Chrome 访问开发者后台吗？(y/N): "
        read -r answer
        case "$answer" in
            y|Y)
                osascript -e 'quit app "Google Chrome"' 2>/dev/null || true
                sleep 3
                killall "Google Chrome" 2>/dev/null || true
                open -a "Google Chrome" --args \
                    --proxy-server="http://${CLASH_HOST}:${port}" \
                    --proxy-bypass-list="$bypass_str" \
                    --disable-quic \
                    "$CHECK_URL"
                log "Chrome 已用修复后的代理参数重新打开"
                ;;
            *)
                warn "已跳过重启 Chrome；如果网页仍打不开，请手动完全退出 Chrome 后重新打开。"
                ;;
        esac
    fi
}

validate_now() {
    local host="ai.limayao.com"
    local ip iface http_code
    echo ""
    echo "---------------- 验证 ----------------"
    ip=$(resolve_real_ipv4 "$host" || true)
    if [ -n "$ip" ]; then
        iface=$(route_iface_for_ip "$ip")
        log "$host 解析到 $ip，路由接口: ${iface:-未知}"
    else
        err "$host 未解析到真实内网 IP"
    fi

    http_code=$(curl -kL --connect-timeout 5 --max-time 12 --noproxy "*" -o /dev/null -w "%{http_code}" "$CHECK_URL" 2>/dev/null)
    if [ "$http_code" = "200" ] || [ "$http_code" = "302" ]; then
        log "$CHECK_URL 直连可访问，HTTP $http_code"
    else
        err "$CHECK_URL 直连仍不可访问，HTTP ${http_code:-000}"
    fi

    http_code=$(curl -kL --connect-timeout 5 --max-time 12 -x "http://${CLASH_HOST}:${CLASH_PORT}" -o /dev/null -w "%{http_code}" "https://www.google.com" 2>/dev/null)
    if [ "$http_code" = "200" ] || [ "$http_code" = "301" ] || [ "$http_code" = "302" ]; then
        log "外网代理可访问 Google，HTTP $http_code"
    else
        warn "外网代理检测未通过，HTTP ${http_code:-000}。这不一定影响 limayao 内网直连。"
    fi
}

CLASH_PORT=$(detect_clash_port)
log "检测到 Clash/Mihomo 代理端口: ${CLASH_HOST}:${CLASH_PORT}"

echo ""
echo "---------------- 解析公司域名 ----------------"
for host in "${DIRECT_HOSTS[@]}"; do
    ip=$(resolve_real_ipv4 "$host" || true)
    if [ -n "$ip" ]; then
        range=$(route_range_for_ip "$ip" || true)
        add_unique_range "$range"
        log "$host -> $ip，加入/确认内网网段 ${range:-未知}"
    else
        warn "$host 暂未解析到真实 IP"
    fi
done

VPN_IF=$(detect_vpn_iface || true)
if [ -n "$VPN_IF" ]; then
    log "检测到公司 VPN 接口: $VPN_IF"
else
    warn "未检测到公司 VPN 接口。请先连接 SASE/OpenVPN 后再运行本脚本。"
fi

DNS_POLICY=$(corp_dns_policy_value)
log "Clash 公司域名 DNS 策略: $DNS_POLICY"

write_clash_merge_config "$DNS_POLICY"
patch_running_clash_configs "$DNS_POLICY"
reload_clash
set_system_proxy_and_env "$CLASH_PORT"
write_guard "$CLASH_PORT"
write_chrome_policy "$CLASH_PORT"
add_temp_routes_if_needed "$VPN_IF"
flush_dns_cache
validate_now
restart_chrome_prompt "$CLASH_PORT"

echo ""
echo "============================================================"
echo "修复执行完毕。日志文件: $LOG_FILE"
echo "如果仍打不开，请把这个日志文件发回来。"
echo "============================================================"
echo ""

read -p "按回车退出..." _
