# MergeSASE

最新更新 v1.2：修复开发者余额显示口径、授权地址配置和登录态隐私说明。

**遇到损坏无法打开，终端执行**
xattr -cr（把app直接拖到终端里）
就可以打开了。

注意想要让自己的公司内部网络生效需要在公司域名那边添加下自己公司的域名，xxxx.com

> 注意：`api.company.internal` 解析到 SASE 内网地址，ccswitch/Codex 等应用需要直连它。MergeSASE 会把这个精确 host 写进 `NO_PROXY/no_proxy`，并清理 `ALL_PROXY/all_proxy`，避免内网请求被强制兜底送入 Clash。

## 快速开始

### 方式一：从 GitHub Releases 下载安装（推荐给普通用户）

打开仓库的 Releases 页面：

https://github.com/wangziheng2211222/MergeSASE/releases

下载最新版本里的 `MergeSASE.zip`，解压后双击 `MergeSASE.app` → 点击「一键启动」。

如果 macOS 提示应用损坏或无法打开，执行：

```bash
xattr -cr MergeSASE.app
open MergeSASE.app
```

- 自动检测 Clash 端口、配置路由排除、设置系统代理、部署守护、重启 Chrome
- 修复 Codex/ccswitch/Claude Code 等应用级代理环境：公网继续走 Clash，公司 LLM API 直连 SASE
- 运行态识别 `verge-mihomo` / Clash Verge service，避免 Clash 实际运行但界面误报“未运行”
- 实时状态监控、网络连通性检测、域名管理、日志查看

### 方式二：从源码构建

```bash
git clone https://github.com/wangziheng2211222/MergeSASE.git
cd MergeSASE/MergeSASE
bash build.sh
open MergeSASE.app
```

想放进「应用程序」目录，可以在打包完成后执行：

```bash
cp -R MergeSASE.app /Applications/
```

### 方式三：命令行脚本

```bash
bash clash-sase-fix.command
```

> 注意：GitHub 页面右上角的「Code → Download ZIP」下载的是源码压缩包，不是已打包好的 App。普通用户想直接安装，请下载 Releases 里的 `MergeSASE.zip`。

### 发布安装包给用户

维护者每次修复后可以用下面命令生成安装包，再上传到 GitHub Releases：

```bash
cd MergeSASE
bash build.sh
ditto -c -k --keepParent MergeSASE.app ../MergeSASE.zip
```

## 本次修复说明

这次主要修复开发者余额与授权体验：

- 余额主显示对齐网页 `/developer` 的最终展示口径。网页会先请求 `/api/user/developer-dashboard`，再请求 `/api/user/self/model_quota`，并用 `monthly_overview.display_remaining_quota / 500000` 覆盖当前余额；App 现在也使用这套口径。
- 余额展示支持两位小数，例如 `$102.23`。
- 修复“相比上次”的扣费方向，差值按最终展示余额计算，不再用请求次数推断。
- 清理旧的本地余额缓存，避免重启后继续显示上一次缓存的 `$100.00`。
- 点击「授权登录」前会先检查开发者后台地址；未配置时先让用户输入真实地址，不再直接打开占位域名。
- 授权登录按钮增高，点击区域更明显。

## 余额查询原理

MergeSASE 的余额查询不会在仓库里写死账号、密码或真实 Cookie。它的流程是：

1. 首次点击授权时，App 会要求用户输入开发者后台地址，例如 `https://ai.example.com`。
2. App 内嵌 WebView 打开该后台的登录页，例如 `https://ai.example.com/auth/login`。
3. 用户在网页里扫码或登录完成后，App 只读取该站点下名为 `session_id` 的 Cookie。
4. 读取到的登录态只保存在 App 本次运行的内存里，不写入 Keychain、源码、配置文件或日志。
5. 刷新余额时，App 会向用户配置的后台发起两个请求：
   - `GET /api/user/developer-dashboard`：读取请求数、历史消耗、统计额度、Token 等看板字段。
   - `GET /api/user/self/model_quota`：读取网页实际用于覆盖“当前余额”的模型月额度字段。
6. 如果接口返回 401/403，App 会提示重新授权；开启自动刷新时，每 60 秒用本次运行内的登录态重新查询一次。

文档里的 `developer.company.internal` 和 `api.company.internal` 都是占位域名。实际使用时，请在本地应用里配置自己的公司域名，不要把真实域名、Cookie 或 session 值提交到 Git。

## 登录态和隐私

用户最关心的是：授权登录会不会把密钥、Cookie 或公司后台地址传给别人。当前实现遵循下面的边界：

- App 不会读取 API Key 内容，也不会读取网页里的 `Authorization: Bearer sk-xxx` 示例或用户创建的密钥。
- App 只从内嵌 WebView 的 Cookie 里读取当前配置域名下的 `session_id`，用于请求同一个后台的余额接口。
- `session_id` 只存在当前 App 进程内存里；退出 App 后需要重新授权。
- `session_id` 不写入 Git、不写入 README、不写入日志、不写入 Keychain、不写入 UserDefaults。
- App 只把 `session_id` 作为 Cookie 发给用户自己配置的开发者后台域名，不会发给 GitHub、作者服务器或第三方统计服务。
- 后台地址会保存到本机 `UserDefaults`，方便下次打开时不用重新输入；它不是登录密钥。

如果仍然担心，可以从 Git 克隆源码后自己检查 `MergeSASE/Sources/ProxyService.swift` 和 `MergeSASE/Sources/ContentView.swift`，再用 `bash build.sh` 在本机打包运行。

<!-- 旧版说明保留在 Git 历史中。 -->

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
