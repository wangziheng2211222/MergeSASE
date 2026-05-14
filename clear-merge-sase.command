#!/bin/bash
# ============================================================
# MergeSASE 一键清除 — 停止所有共存方案相关服务
# 双击 .command 即可运行
# ============================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; }

echo ""
echo "  ╔══════════════════════════════════╗"
echo "  ║   MergeSASE 一键清除           ║"
echo "  ╚══════════════════════════════════╝"
echo ""
warn "将停止以下服务/配置:"
echo "  1. launchd 代理守护 (com.clash.proxyguard)"
echo "  2. launchd 环境代理 (com.clash.envproxy)"
echo "  3. 系统代理设置 (networksetup)"
echo "  4. Chrome 策略代理"
echo "  5. launchctl 环境变量"
echo "  6. MergeSASE.app"
echo "  7. Clash Verge (clash-verge + mihomo 内核)"
echo "  8. Chrome (带代理参数启动的实例)"
echo ""

read -p "确认执行? (y/N): " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "已取消"
    exit 0
fi

# ---------- 1. 停止 launchd 守护 ----------
log "停止 launchd 守护..."
PLIST_PATH="$HOME/Library/LaunchAgents/com.clash.proxyguard.plist"
ENV_PROXY_PLIST="$HOME/Library/LaunchAgents/com.clash.envproxy.plist"

if [ -f "$PLIST_PATH" ]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null && log "  已卸载 com.clash.proxyguard" || warn "  卸载 com.clash.proxyguard 失败（可能未加载）"
    rm -f "$PLIST_PATH" && log "  已删除 $PLIST_PATH"
else
    log "  com.clash.proxyguard plist 不存在，跳过"
fi

if [ -f "$ENV_PROXY_PLIST" ]; then
    launchctl unload "$ENV_PROXY_PLIST" 2>/dev/null && log "  已卸载 com.clash.envproxy" || warn "  卸载 com.clash.envproxy 失败（可能未加载）"
    rm -f "$ENV_PROXY_PLIST" && log "  已删除 $ENV_PROXY_PLIST"
else
    log "  com.clash.envproxy plist 不存在，跳过"
fi

# ---------- 2. 清除系统代理 ----------
log "清除系统代理设置..."
while IFS= read -r service; do
    [ -z "$service" ] && continue
    case "$service" in \**) continue ;; esac
    networksetup -setwebproxystate "$service" off 2>/dev/null || true
    networksetup -setsecurewebproxystate "$service" off 2>/dev/null || true
    networksetup -setsocksfirewallproxystate "$service" off 2>/dev/null || true
    networksetup -setproxybypassdomains "$service" "" 2>/dev/null || true
done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)
log "  系统代理已全部关闭"

# ---------- 3. 清除 Chrome 策略代理 ----------
log "清除 Chrome 策略代理..."
CHROME_PLIST="$HOME/Library/Preferences/com.google.Chrome.plist"
if [ -f "$CHROME_PLIST" ]; then
    defaults delete "$CHROME_PLIST" ProxySettings 2>/dev/null && log "  已清除 Chrome ProxySettings" || log "  Chrome ProxySettings 不存在，跳过"
else
    log "  Chrome plist 不存在，跳过"
fi

# ---------- 4. 清除 launchctl 环境变量 ----------
log "清除 launchctl 环境变量..."
for key in HTTP_PROXY http_proxy HTTPS_PROXY https_proxy NO_PROXY no_proxy; do
    launchctl unsetenv "$key" 2>/dev/null || true
done
log "  代理环境变量已清除"

# ---------- 5. 停止 MergeSASE.app ----------
log "停止 MergeSASE.app..."
pkill -f "MergeSASE.app" 2>/dev/null && log "  MergeSASE.app 已终止" || log "  MergeSASE.app 未在运行"

# ---------- 6. 停止 Clash Verge ----------
log "停止 Clash Verge..."
pkill -f "Clash Verge.app" 2>/dev/null && log "  Clash Verge 已终止" || log "  Clash Verge 未在运行"
# 等待 mihomo 内核退出
sleep 1
pkill -f "verge-mihomo" 2>/dev/null && log "  mihomo 内核已终止" || log "  mihomo 内核未在运行"

# ---------- 7. 停止 Chrome（仅带代理参数的实例）----------
log "停止带代理参数的 Chrome 实例..."
# 匹配包含 --proxy-server 参数的 Chrome 进程
CHROME_PROXY_PIDS=$(ps aux | grep "Google Chrome" | grep "\-\-proxy-server" | grep -v grep | awk '{print $2}')
if [ -n "$CHROME_PROXY_PIDS" ]; then
    echo "$CHROME_PROXY_PIDS" | while read pid; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done
    log "  带代理参数的 Chrome 实例已终止"
else
    log "  无带代理参数的 Chrome 实例"
fi

# ---------- 8. 清理守护脚本 ----------
GUARD_SCRIPT="$HOME/.local/bin/clash-proxy-guard.sh"
if [ -f "$GUARD_SCRIPT" ]; then
    rm -f "$GUARD_SCRIPT" && log "已删除守护脚本: $GUARD_SCRIPT"
fi

echo ""
echo -e "  ${GREEN}✓ MergeSASE 全部组件已清除${NC}"
echo ""
echo -e "  ${YELLOW}注意:${NC} SASE VPN 仍在运行，如需停止请手动退出 SASE.app"
echo ""
