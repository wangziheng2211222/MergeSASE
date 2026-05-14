#!/bin/bash
# ============================================================
# Clash + SASE 共存守护 — 双击 .command 即可运行
# 用途：让 Clash 系统代理和公司 SASE VPN 同时工作
# 原理：监听系统代理设置，SASE 一清就立刻抢回来（事件驱动，非轮询）
# ============================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; }

# ---------- 自动检测 Clash 端口 ----------
detect_port() {
    # 先尝试从常见路径的配置文件读取
    local configs=(
        "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/config.yaml"
        "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml"
        "$HOME/.config/clash/config.yaml"
        "$HOME/.config/mihomo/config.yaml"
    )
    for f in "${configs[@]}"; do
        if [ -f "$f" ]; then
            local port
            port=$(grep -E '^mixed-port:|^mixed_port:' "$f" 2>/dev/null | grep -o '[0-9]\+' | head -1)
            if [ -n "$port" ]; then
                echo "$port"
                return
            fi
        fi
    done
    # 从当前进程找
    local port
    port=$(ps aux 2>/dev/null | grep -iE 'mihomo|clash' | grep -o 'mixed-port[= ][0-9]\+' | grep -o '[0-9]\+' | head -1)
    if [ -n "$port" ]; then
        echo "$port"
        return
    fi
    # 从监听端口找
    port=$(lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null | grep -iE 'mihomo|clash' | grep -o '127.0.0.1:[0-9]\+' | cut -d: -f2 | head -1)
    if [ -n "$port" ]; then
        echo "$port"
        return
    fi
    # 默认
    echo "7897"
}

CLASH_PORT=$(detect_port)
CLASH_HOST="127.0.0.1"

# ---- 公司内部域名（按需添加）----
COMPANY_DOMAINS=(
    "cds8.cn"
    "limayao.com"
)
DIRECT_COMPANY_HOSTS=(
    "ai.limayao.com"
    "ai-platform-cicada-llm-api.limayao.com"
)
PROXY_REQUIRED_HOSTS=()
# ---- 还可以在这里继续添加，例如: "company.com" "internal.corp" ----

GUARD_SCRIPT="$HOME/.local/bin/clash-proxy-guard.sh"
PLIST_PATH="$HOME/Library/LaunchAgents/com.clash.proxyguard.plist"

echo ""
echo "  ╔══════════════════════════════════╗"
echo "  ║   Clash + SASE 共存守护        ║"
echo "  ╚══════════════════════════════════╝"
echo ""
log "检测到 Clash 代理端口: ${CLASH_HOST}:${CLASH_PORT}"

# ---------- 1. 写入守护脚本 ----------
mkdir -p "$(dirname "$GUARD_SCRIPT")"
DOMAIN_LINES=""
for d in "${COMPANY_DOMAINS[@]}"; do
    DOMAIN_LINES+="    \"$d\""$'\n'
done
DIRECT_HOST_LINES=""
for d in "${DIRECT_COMPANY_HOSTS[@]}"; do
    DIRECT_HOST_LINES+="    \"$d\""$'\n'
done
PROXY_REQUIRED_LINES=""
for d in "${PROXY_REQUIRED_HOSTS[@]}"; do
    PROXY_REQUIRED_LINES+="    \"$d\""$'\n'
done

cat > "$GUARD_SCRIPT" << SCRIPT_EOF
#!/bin/bash
# --- Clash Proxy Guard (auto-generated) ---
CLASH_HOST="${CLASH_HOST}"
CLASH_PORT="${CLASH_PORT}"

COMPANY_DOMAINS=(
${DOMAIN_LINES}
)
DIRECT_COMPANY_HOSTS=(
${DIRECT_HOST_LINES}
)
PROXY_REQUIRED_HOSTS=(
${PROXY_REQUIRED_LINES}
)

BYPASS=(
    "127.0.0.1"
    "localhost"
    "*.local"
    "169.254.0.0/16"
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "197.19.0.0/16"
    "cds8.cn"
    "*.cds8.cn"
    "limayao.com"
    "*.limayao.com"
    "\${DIRECT_COMPANY_HOSTS[@]}"
)

while IFS= read -r service; do
    [ -z "\$service" ] && continue
    case "\$service" in \\**) continue ;; esac
    networksetup -setwebproxy "\$service" "\$CLASH_HOST" "\$CLASH_PORT" 2>/dev/null || true
    networksetup -setsecurewebproxy "\$service" "\$CLASH_HOST" "\$CLASH_PORT" 2>/dev/null || true
    networksetup -setsocksfirewallproxy "\$service" "\$CLASH_HOST" "\$CLASH_PORT" 2>/dev/null || true
    networksetup -setproxybypassdomains "\$service" "\${BYPASS[@]}" 2>/dev/null || true
done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)
SCRIPT_EOF

chmod +x "$GUARD_SCRIPT"
log "守护脚本已写入: $GUARD_SCRIPT"

# ---------- 2. 写入 launchd plist ----------
mkdir -p "$(dirname "$PLIST_PATH")"
cat > "$PLIST_PATH" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.clash.proxyguard</string>
    <key>ProgramArguments</key>
    <array>
        <string>${GUARD_SCRIPT}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>WatchPaths</key>
    <array>
        <string>/Library/Preferences/SystemConfiguration/preferences.plist</string>
    </array>
    <key>ThrottleInterval</key>
    <integer>2</integer>
    <key>StandardOutPath</key>
    <string>${HOME}/Library/Logs/clash-proxy-guard.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/Library/Logs/clash-proxy-guard.log</string>
</dict>
</plist>
PLIST_EOF
log "launchd 配置已写入: $PLIST_PATH"

# ---------- 3. 立即设置代理 ----------
BYPASS_ARGS=(
    "127.0.0.1" "localhost" "*.local" "169.254.0.0/16"
    "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "197.19.0.0/16"
    "cds8.cn" "*.cds8.cn" "limayao.com" "*.limayao.com" "${DIRECT_COMPANY_HOSTS[@]}"
)

while IFS= read -r service; do
    [ -z "$service" ] && continue
    case "$service" in \**) continue ;; esac
    networksetup -setwebproxy "$service" "$CLASH_HOST" "$CLASH_PORT" 2>/dev/null || true
    networksetup -setsecurewebproxy "$service" "$CLASH_HOST" "$CLASH_PORT" 2>/dev/null || true
    networksetup -setsocksfirewallproxy "$service" "$CLASH_HOST" "$CLASH_PORT" 2>/dev/null || true
    networksetup -setproxybypassdomains "$service" "${BYPASS_ARGS[@]}" 2>/dev/null || true
done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)
log "系统代理已设置为 ${CLASH_HOST}:${CLASH_PORT}"

# ccswitch 等非浏览器应用通常读取 launchd 环境变量。
# 额外写入精确 API host，兼容不识别 *.limayao.com 的客户端。
PROXY_URL="http://${CLASH_HOST}:${CLASH_PORT}"
NO_PROXY_VALUE="localhost,127.0.0.1,::1,.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,197.19.0.0/16,cds8.cn,.cds8.cn,*.cds8.cn,limayao.com,.limayao.com,*.limayao.com,ai.limayao.com,ai-platform-cicada-llm-api.limayao.com"
for key in HTTP_PROXY http_proxy HTTPS_PROXY https_proxy; do
    launchctl setenv "$key" "$PROXY_URL"
done
for key in NO_PROXY no_proxy; do
    launchctl setenv "$key" "$NO_PROXY_VALUE"
done
log "应用代理环境已设置；ccswitch 重启后会直连 SASE 访问 LLM API"

# ---------- 4. 加载 launchd ----------
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"
log "守护已启动（事件驱动，SASE 清代理时 2 秒内恢复）"

# ---------- 验证 ----------
sleep 1
HTTP_ENABLE=$(scutil --proxy 2>/dev/null | grep HTTPEnable | awk '{print $3}')
if [ "$HTTP_ENABLE" = "1" ]; then
    echo ""
    echo -e "  ${GREEN}✓ 一切就绪${NC}"
    echo -e "  Clash 代理: ${CLASH_HOST}:${CLASH_PORT}"
    echo -e "  守护模式:   事件驱动（WatchPaths）"
    echo -e "  当前状态:   系统代理已启用"
else
    warn "代理设置可能未生效，请手动确认"
fi

echo ""
echo -e "  ${YELLOW}关闭方法:${NC}"
echo -e "  重新运行本脚本，或执行:"
echo -e "  launchctl unload ~/Library/LaunchAgents/com.clash.proxyguard.plist"
echo ""
