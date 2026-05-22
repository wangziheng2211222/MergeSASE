# MergeSASE&OpenVPN

最新更新 v1.5：外网代理支持在自动 / Clash / Shadowrocket 之间选择；公司 VPN 适配支持 SASE 和 OpenVPN Connect。

**遇到损坏无法打开，终端执行**
xattr -cr（把app直接拖到终端里）
就可以打开了。

注意想要让自己的公司内部网络生效，需要先连接 SASE 或 OpenVPN Connect，并在公司域名那边添加下自己公司的域名，xxxx.com

> 注意：`api.company.internal` 解析到公司 VPN 内网地址，ccswitch/Codex 等应用需要直连它。MergeSASE&OpenVPN 会把这个精确 host 写进 `NO_PROXY/no_proxy`，并清理 `ALL_PROXY/all_proxy`，避免内网请求被强制兜底送入 Clash。

## 快速开始

### 方式一：从 GitHub Releases 下载安装（推荐给普通用户）

打开仓库的 Releases 页面：

https://github.com/wangziheng2211222/MergeSASE/releases

下载最新版本里的 `MergeSASE&OpenVPN.zip`，解压后双击 `MergeSASE&OpenVPN.app` → 点击「一键启动」。

如果 macOS 提示应用损坏或无法打开，执行：

```bash
xattr -cr "MergeSASE&OpenVPN.app"
open "MergeSASE&OpenVPN.app"
```

- 自动检测或手动选择外网代理：Clash / Shadowrocket
- Clash 模式会配置路由排除；Shadowrocket 模式会接管系统代理、Chrome 和应用环境，但不会写 Clash 专属配置
- 识别 SASE / OpenVPN Connect 等公司 VPN 客户端，状态区显示当前虚拟网卡
- 修复 Codex/ccswitch/Claude Code 等应用级代理环境：公网继续走外网代理，公司 LLM API 直连公司 VPN
- 运行态识别 `verge-mihomo` / Clash Verge service，避免 Clash 实际运行但界面误报“未运行”
- 实时状态监控、网络连通性检测、域名管理、日志查看

### 方式二：从源码构建

```bash
git clone https://github.com/wangziheng2211222/MergeSASE.git
cd MergeSASE/MergeSASE
bash build.sh
open "MergeSASE&OpenVPN.app"
```

想放进「应用程序」目录，可以在打包完成后执行：

```bash
cp -R "MergeSASE&OpenVPN.app" /Applications/
```

### 方式三：命令行脚本

```bash
bash clash-sase-fix.command
```

> 注意：GitHub 页面右上角的「Code → Download ZIP」下载的是源码压缩包，不是已打包好的 App。普通用户想直接安装，请下载 Releases 里的 `MergeSASE&OpenVPN.zip`。

### 发布安装包给用户

维护者每次修复后可以用下面命令生成安装包，再上传到 GitHub Releases：

```bash
cd MergeSASE
bash build.sh
ditto -c -k --keepParent "MergeSASE&OpenVPN.app" "../MergeSASE&OpenVPN.zip"
```

## 本次修复说明

这次调整开发者余额配置方式：

- App 不再提供独立的「配置 Key」按钮，展开「配置 Key」区域后可以直接编辑 Key 列表。
- App 不再显示刷新余额、删除 Key 等操作按钮。
- 余额接口固定使用 `https://ai-platform-cicada-llm-api.limayao.com/api/usage/token/balance`，不暴露给用户配置。
- 配置 Key 后，App 会自动读取并显示余额。

文档里的 `developer.company.internal` 和 `api.company.internal` 都是占位域名。实际使用时，请在本地应用里配置自己的公司域名，不要把真实域名、Cookie、session 值或 API Key 提交到 Git。

## 问题背景

公司 VPN（SASE、OpenVPN Connect 等）会创建虚拟网卡接管 DNS 和路由表，Clash 或 Shadowrocket 负责外网代理。Clash 开 TUN 时还会劫持 DNS 和路由，两者同时开启会产生多层冲突：

```
┌─────────────────────────────────────────────┐
│            macOS 网络栈                      │
│  ┌──────────┐    ┌──────────┐              │
│  │外网代理  │    │公司 VPN  │              │
│  │(utun1024)│    │ (utun6)  │              │
│  │ TUN 模式 │    │ VPN 隧道 │              │
│  └────┬─────┘    └────┬─────┘              │
│       └────────┬───────┘                     │
│               ▼                             │
│         路由表—两者争抢默认路由和 DNS        │
└─────────────────────────────────────────────┘
```

### 冲突 1：系统代理层
- 部分公司 VPN 会**清除系统代理设置**
- 即使用 `networksetup` 设置代理，Chrome 也不生效

### 冲突 2：TUN DNS 劫持
- Clash TUN 劫持 DNS（`any:53`），返回假 IP（`198.18.x.x`）
- 公司内网域名被解析为假 IP → 无法访问
- Shadowrocket 没有 Clash Verge 的 `merge.yaml`，需要在 Shadowrocket 内确认公司域名走直连

### 冲突 3：Chrome 不走系统代理
- Chrome 读全局代理状态，忽略系统代理绕过列表
- QUIC/HTTP3 走 UDP，绕过 HTTP 代理

## 解决方案架构

四层防护，每层解决一个冲突：

```
层级 1: DNS → fake-ip-filter 排除公司域名
  └─ *.company.internal 返回真实 IP

层级 2: TUN → route-exclude 排除内网 IP（Clash 模式）
  └─ 内网流量不经过 Clash TUN，走公司 VPN 隧道

层级 3: 系统代理 → launchd 守护
  └─ 公司 VPN 清代理 → 2 秒内自动恢复

层级 4: Chrome → 命令行参数强制代理
  └─ --proxy-server + --proxy-bypass-list（关键）
```

## 流量路径

```
访问 google.com:
  Chrome → PROXY 127.0.0.1:端口 → Clash/Shadowrocket → 代理节点 ✅

访问 api.company.internal:
  Chrome → bypass *.company.internal → DIRECT
    → DNS 返回真实 IP → 公司 VPN 隧道(utun/tun/tap) → 公司内网 ✅

访问 baidu.com:
  Chrome → Clash → GEOIP,CN → DIRECT → 本地网络 ✅
```

## 文件说明

| 路径 | 用途 |
|------|------|
| `MergeSASE&OpenVPN.app` | macOS GUI 应用，一键启动/停止 |
| `MergeSASE/Sources/` | SwiftUI 源码 |
| `clash-sase-fix.command` | 命令行部署脚本 |
| `Merge.yaml` | Clash Verge 合并配置模板，Shadowrocket 模式不会使用 |
| `com.clash.proxyguard.plist` | launchd 守护配置 |
| `解决方案.md` | 详细技术方案与踩坑记录 |

## 构建

```bash
cd MergeSASE
bash build.sh
```

需要 macOS 14+ 及 Xcode 15+。

## 排查问题

详见 App 内日志面板，或命令行诊断：

```bash
# DNS 是否返回假 IP
dig your-company-domain +short
# 198.18.x.x = 假 IP ❌   10.x.x.x = 真实 IP ✅

# 路由是否正确
route -n get <公司内网IP>
# interface: utun/tun/tap = 公司 VPN ✅   interface: Clash TUN = 需要检查 route-exclude ❌

# 重置
bash clash-sase-fix.command
```
