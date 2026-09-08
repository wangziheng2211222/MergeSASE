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

兼容范围：macOS 13 或更高版本，支持 Intel 和 Apple Silicon。macOS 12 及更早版本不支持当前菜单栏界面。

### 终端安装（2.1 正式发布后）

当前 2.1 版本尚未上传 GitHub Release。发布完成后使用：

```bash
curl -fL https://raw.githubusercontent.com/wangziheng2211222/MergeSASE/2.1/install.sh | VERSION=2.1 bash
```

脚本只会下载指定版本的 GitHub Release，校验版本、SHA-256、Universal 2 架构、签名和公证后，再安装到 `/Applications/蝉舒宝.app`。

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
RELEASE_DIR="$(mktemp -d)"
SIGN_IDENTITY="Developer ID Application: ..." \
NOTARY_PROFILE="notary-profile" \
EXPECTED_TEAM_ID="你的 Apple Team ID" \
PACKAGE_PATH="$RELEASE_DIR/ChanShuBao.zip" \
PACKAGE=1 RELEASE_VERSION=2.1 bash build.sh
```

正式发布前，先把 `install.sh` 中的 `EXPECTED_TEAM_ID` 改成同一个 Apple Team ID。提交并推送 `2.1` 标签后，创建 GitHub Release，并同时上传 `ChanShuBao.zip` 与 `ChanShuBao.zip.sha256`。最后用上面的终端安装命令在未安装蝉舒宝的测试账户中验证一次。当前仓库根目录里的旧 ZIP 不作为 2.1 发布来源。

## 使用流程

1. 打开蝉舒宝，启动页会先显示“我会稳稳地接住你 / - 蝉舒宝 -”，随后进入重点清单。
2. 如果缺少 OpenVPN Connect，点击“下载”；如果已安装但未连接，点击“打开”后连接公司 VPN profile。
3. 如果缺少 CC Switch，点击“安装”，在终端里完成安装；如果缺少 Codex 桌面版，点击“下载安装”并按打开的页面手动安装。
4. 点击“导入”，在 App 内置浏览器里登录 limayao 开发者后台。
5. 登录完成后点击“导入当前页面”。成功后会唤起 CC Switch，并把 API Key 保存到本机用于余额查询。
6. 配置公司域名，确保默认的 `cds8.cn`、`limayao.com` 或你的公司域名在列表中。
7. 如果需要同时使用外网代理，建议使用 Clash Verge Rev 的系统代理模式；选择 Shadowrocket 时，需要确认其已连接并填写 Proxy Port。

## 隐私与凭据

- 蝉舒宝不保存网页登录态、Cookie 或 session。
- API Key 仅保存在本机偏好设置中，用于余额查询；不会读取或保存网页登录态。
- CC Switch provider 通过 `ccswitch://` 深链交给 CC Switch 自己导入，蝉舒宝不直接写 `~/.cc-switch/cc-switch.db`。
- Codex 的 provider/auth 由 CC Switch 同步，蝉舒宝不直接写 Codex 认证文件。

## 网络说明

公司 VPN（SASE、OpenVPN Connect、GlobalProtect、Zscaler、Netskope、Cisco AnyConnect 等）和外网代理同时运行时，容易出现 DNS、TUN、系统代理和 Chrome 策略冲突。正式推荐让公司 VPN 独占 TUN，Clash Verge Rev 只开启系统代理。Shadowrocket 的 PacketTunnel 与公司 VPN 共存属于兼容模式，最终以内网和代理外网实测为准。蝉舒宝会：

- 为公司域名写入 Clash fake-ip/filter 和直连规则。
- 为系统代理、Chrome 策略、launchd 环境变量写入绕过列表。
- 在 `~/.codex/.env` 写入 HTTP(S)_PROXY 和 NO_PROXY，并清理 ALL_PROXY，避免公司内网请求被强制送入外网代理。
- 停止时按启动前快照恢复系统代理、Chrome、Clash 和环境变量。
- 只有确认公司 VPN、外网代理、活动物理网卡以及内外网实测全部通过后，才显示“运行中”；连接中断时自动恢复启动前配置。

默认公司域名包含 `cds8.cn` 和 `limayao.com`，你可以在界面里增删自己的公司域名。

## 排查

如果 macOS 提示应用损坏或无法打开，不要清除隔离属性。请删除该文件，并从指定版本的 GitHub Release 重新下载安装；安装器会重新检查 SHA-256、应用身份、Developer ID 签名和 Gatekeeper 公证结果。

如果导入失败：

- 先确认已在内置浏览器登录 `https://ai.limayao.com/developer`。
- 仍失败时，手动复制 API Key 到余额查询输入框，并在后台手动点击 CC Switch 导入按钮。

构建需要 macOS 13+ 和 Xcode 15+。
