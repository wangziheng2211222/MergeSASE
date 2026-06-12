# 蝉舒宝

蝉舒宝是一个 macOS Codex 使用前置配置助手。它优先帮用户完成三件事：安装 CC Switch、安装 Codex 桌面版、导入公司的 CC Switch 信息。之后再引导用户连接 SASE/OpenVPN，并按需要启动 Codex 网络守护，让内网直连、外网走代理。

## 功能

- 检测 CC Switch 和 Codex 桌面版。
- 检测 OpenVPN Connect；未安装时打开官方客户端下载页，已安装时直接打开 App 让用户连接 profile。
- 安装 CC Switch 时打开终端自动执行安装流程，过程中可能需要输入本机密码。
- Codex 桌面版不在后台自动安装，点击后打开 `https://chatgpt.com/zh-Hans-CN/features/desktop/`，由用户按官方页面手动安装。
- 在 App 内置浏览器打开 `https://ai.limayao.com/developer`，用户自行授权登录。
- 从内置浏览器当前页面读取 `.ccswitch-dropdown-item.ccswitch-dropdown-item--both` 附近内容，优先提取 `ccswitch://` 深链并唤起 CC Switch 导入。
- 从同一页面提取 API Key，保存在本机偏好设置里，并自动查询余额。
- 保留公司 VPN、Clash/Shadowrocket、Chrome 策略、launchd 网络守护和 `~/.codex/.env` 配置能力。

## 快速开始

### 终端安装

```bash
curl -fL https://raw.githubusercontent.com/wangziheng2211222/MergeSASE/main/install.sh | bash
```

脚本会下载最新发布包，安装到 `/Applications/蝉舒宝.app`，清除隔离属性并启动 App。

### 从源码构建

```bash
git clone https://github.com/wangziheng2211222/MergeSASE.git
cd MergeSASE/MergeSASE
bash build.sh
open "蝉舒宝.app"
```

发布安装包：

```bash
cd MergeSASE
PACKAGE=1 bash build.sh
```

## 使用流程

1. 打开蝉舒宝，启动页会先显示“我会稳稳地接住你 / - 蝉舒宝 -”，随后进入重点清单。
2. 如果缺少 OpenVPN Connect，点击“下载”；如果已安装但未连接，点击“打开”后连接公司 VPN profile。
3. 如果缺少 CC Switch，点击“安装”，在终端里完成安装；如果缺少 Codex 桌面版，点击“下载安装”并按打开的页面手动安装。
4. 点击“导入”，在 App 内置浏览器里登录 limayao 开发者后台。
5. 登录完成后点击“导入当前页面”。成功后会唤起 CC Switch，并把 API Key 保存到本机用于余额查询。
6. 配置公司域名，确保默认的 `cds8.cn`、`limayao.com` 或你的公司域名在列表中。
7. 如果需要同时使用外网代理，点击“一键配置 Codex 环境”启动网络守护，让公司内网直连 VPN、外网走 Clash/Shadowrocket。

## 隐私与凭据

- 蝉舒宝不保存网页登录态、Cookie 或 session。
- API Key 仅保存在本机偏好设置中，用于余额查询；不会读取或保存网页登录态。
- CC Switch provider 通过 `ccswitch://` 深链交给 CC Switch 自己导入，蝉舒宝不直接写 `~/.cc-switch/cc-switch.db`。
- Codex 的 provider/auth 由 CC Switch 同步，蝉舒宝不直接写 Codex 认证文件。

## 网络说明

公司 VPN（SASE、OpenVPN Connect、GlobalProtect、Zscaler、Netskope、Cisco AnyConnect 等）和外网代理（Clash/Shadowrocket）同时运行时，容易出现 DNS、TUN、系统代理和 Chrome 策略冲突。蝉舒宝会：

- 为公司域名写入 Clash fake-ip/filter 和直连规则。
- 为系统代理、Chrome 策略、launchd 环境变量写入绕过列表。
- 在 `~/.codex/.env` 写入 HTTP(S)_PROXY 和 NO_PROXY，并清理 ALL_PROXY，避免公司内网请求被强制送入外网代理。
- 停止时按启动前快照恢复系统代理、Chrome、Clash 和环境变量。

默认公司域名包含 `cds8.cn` 和 `limayao.com`，你可以在界面里增删自己的公司域名。

## 排查

如果 macOS 提示应用损坏或无法打开：

```bash
xattr -cr "蝉舒宝.app"
open "蝉舒宝.app"
```

如果导入失败：

- 先确认已在内置浏览器登录 `https://ai.limayao.com/developer`。
- 仍失败时，手动复制 API Key 到余额查询输入框，并在后台手动点击 CC Switch 导入按钮。

构建需要 macOS 13+ 和 Xcode 15+。
