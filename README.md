# MergeSASE — Clash + SASE VPN 共存方案

## 快速开始

### 方式一：MergeSASE.app（推荐）

双击 `MergeSASE.app` → 点击「一键启动」。

- 自动检测 Clash 端口、配置路由排除、设置系统代理、部署守护、重启 Chrome
- 实时状态监控、网络连通性检测、域名管理、日志查看

### 方式二：命令行

```bash
bash clash-sase-fix.command
```

## 问题背景

SASE VPN 创建虚拟网卡接管 DNS 和路由表，Clash 也需要 TUN 模式劫持流量，两者同时开启产生多层冲突：

```
┌─────────────────────────────────────────────┐
│            macOS 网络栈                      │
│  ┌──────────┐    ┌──────────┐              │
│  │  Clash   │    │  SASE    │              │
│  │(utun1024)│    │ (utun6)  │              │
│  │ TUN 模式 │    │ VPN 隧道 │              │
│  └────┬─────┘    └────┬─────┘              │
│       └────────┬───────┘                     │
│               ▼                             │
│         路由表—两者争抢默认路由和 DNS        │
└─────────────────────────────────────────────┘
```

### 冲突 1：系统代理层
- SASE 会**清除系统代理设置**
- 即使用 `networksetup` 设置代理，Chrome 也不生效

### 冲突 2：TUN DNS 劫持
- Clash TUN 劫持 DNS（`any:53`），返回假 IP（`198.18.x.x`）
- 公司内网域名被解析为假 IP → 无法访问

### 冲突 3：Chrome 不走系统代理
- Chrome 读全局代理状态，忽略系统代理绕过列表
- QUIC/HTTP3 走 UDP，绕过 HTTP 代理

## 解决方案架构

四层防护，每层解决一个冲突：

```
层级 1: DNS → fake-ip-filter 排除公司域名
  └─ *.company.internal 返回真实 IP

层级 2: TUN → route-exclude 排除内网 IP
  └─ 内网流量不经过 Clash TUN，走 SASE 隧道

层级 3: 系统代理 → launchd 守护
  └─ SASE 清代理 → 2 秒内自动恢复

层级 4: Chrome → 命令行参数强制代理
  └─ --proxy-server + --proxy-bypass-list（关键）
```

## 流量路径

```
访问 google.com:
  Chrome → PROXY 127.0.0.1:7897 → Clash → 代理节点 ✅

访问 api.company.internal:
  Chrome → bypass *.company.internal → DIRECT
    → DNS 返回真实 IP → SASE 隧道(utun6) → 公司内网 ✅

访问 baidu.com:
  Chrome → Clash → GEOIP,CN → DIRECT → 本地网络 ✅
```

## 文件说明

| 路径 | 用途 |
|------|------|
| `MergeSASE.app` | macOS GUI 应用，一键启动/停止 |
| `MergeSASE/Sources/` | SwiftUI 源码 |
| `clash-sase-fix.command` | 命令行部署脚本 |
| `Merge.yaml` | Clash Verge 合并配置模板 |
| `com.clash.proxyguard.plist` | launchd 守护配置 |
| `解决方案.md` | 详细技术方案与踩坑记录 |

## 构建

```bash
cd MergeSASE
bash build.sh
```

需要 macOS 14+ 及 Xcode 15+。

## 多台电脑部署

1. 将 `MergeSASE.app` 拷贝到目标电脑
2. 在 App 中修改公司域名为实际域名
3. 在 Clash Verge 的「配置增强」中导入 `Merge.yaml`
4. 点击「一键启动」

## 排查问题

详见 App 内日志面板，或命令行诊断：

```bash
# DNS 是否返回假 IP
dig your-company-domain +short
# 198.18.x.x = 假 IP ❌   10.x.x.x = 真实 IP ✅

# 路由是否正确
route -n get <公司内网IP>
# interface: utun6 = SASE ✅   interface: utun1024 = Clash TUN ❌

# 重置
bash clash-sase-fix.command
```

## License

MIT
