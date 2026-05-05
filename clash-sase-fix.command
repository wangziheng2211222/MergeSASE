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
    "company.internal"
)
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
cat > "$GUARD_SCRIPT" << 'SCRIPT_EOF'
#!/bin/bash
# --- Clash Proxy Guard (auto-generated) ---
CLASH_HOST="__CLASH_HOST__"
CLASH_PORT="__CLASH_PORT__"

COMPANY_DOMAINS=(
__COMPANY_DOMAINS__
)

current_host=$(scutil --proxy 2>/dev/null | grep HTTPProxy | awk '{print $3}')
if [ "$current_host" = "$CLASH_HOST" ]; then
    exit 0
fi

BYPASS=(
    "127.0.0.1"
    "localhost"
    "*.local"
    "169.254.0.0/16"
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "\${COMPANY_DOMAINS[@]}"
)

for service in $(networksetup -listallnetworkservices 2>/dev/null | tail -n +2); do
    networksetup -setwebproxy "$service" "$CLASH_HOST" "$CLASH_PORT" 2>/dev/null
    networksetup -setsecurewebproxy "$service" "$CLASH_HOST" "$CLASH_PORT" 2>/dev/null
    networksetup -setsocksfirewallproxy "$service" "$CLASH_HOST" "$CLASH_PORT" 2>/dev/null
    networksetup -setproxybypassdomains "$service" "\${BYPASS[@]}" 2>/dev/null
done
SCRIPT_EOF

sed -i '' "s/__CLASH_HOST__/${CLASH_HOST}/g" "$GUARD_SCRIPT"
sed -i '' "s/__CLASH_PORT__/${CLASH_PORT}/g" "$GUARD_SCRIPT"

# 写入公司域名列表
DOMAIN_LINES=""
for d in "${COMPANY_DOMAINS[@]}"; do
    DOMAIN_LINES+="    \"$d\""$'\n'
done
sed -i '' "s/__COMPANY_DOMAINS__/${DOMAIN_LINES}/g" "$GUARD_SCRIPT"

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
    "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"
    "${COMPANY_DOMAINS[@]}"
)

for service in $(networksetup -listallnetworkservices 2>/dev/null | tail -n +2); do
    networksetup -setwebproxy "$service" "$CLASH_HOST" "$CLASH_PORT" 2>/dev/null || true
    networksetup -setsecurewebproxy "$service" "$CLASH_HOST" "$CLASH_PORT" 2>/dev/null || true
    networksetup -setsocksfirewallproxy "$service" "$CLASH_HOST" "$CLASH_PORT" 2>/dev/null || true
    networksetup -setproxybypassdomains "$service" "${BYPASS_ARGS[@]}" 2>/dev/null || true
done
log "系统代理已设置为 ${CLASH_HOST}:${CLASH_PORT}"

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
