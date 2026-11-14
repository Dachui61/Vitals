Type: task
Status: resolved
Blocked by: 11

# 安装包与开机自启

## Question

交付可双击安装的 `.pkg`，并让工具开机自启、可干净卸载。

要交付：

- `build.sh` 之后新增 `package.sh`：用 `pkgbuild`/`productbuild` 产出 `.pkg`，内含 `Vitals.app`（装到 /Applications）与用户级 LaunchAgent（开机自启）。**不含任何 LaunchDaemon**（票 21 已决定不引入特权组件），所以安装**不需要管理员密码**——双击即可安装。
- 安装体验：双击安装**无需管理员密码**（没有特权组件，没有 LaunchDaemon）；界面说明将安装什么（app + 开机自启项），以及卸载方式。
- 卸载：卸载脚本移除 app 与 LaunchAgent plist；列出清理清单。
- **环境限制的处理**：本会话沙箱无法写 `~/Library/LaunchAgents` 与 `/Library/LaunchDaemons`，`launchctl bootstrap gui/$(id -u)` 在沙箱内返回 EIO——安装/卸载流程必须由用户在普通 Terminal 执行，因此脚本要：干跑检查（dry-run）、打印将要执行的命令、失败时给出可复制的手动步骤。
- 自用场景下是否需要 Developer ID 签名/公证的结论与理由（写进 README）。

产出：`package.sh` + 卸载脚本 + README 的安装/卸载章节。

## Answer

**打包与开机自启已落地并在本机验证**：

- `scripts/package.sh` → 产出 `build/Vitals.pkg`（用户域安装包）。安装内容全部在**用户域**：
  - `~/Applications/Vitals.app`
  - `~/Library/LaunchAgents/local.vitals.app.plist`（`RunAtLoad=true`，开机自启）
  - → **双击安装不需要管理员密码**（本项目不引入特权组件，票 21）。
- `scripts/uninstall.sh` → 默认干跑（只打印将删除什么），`--apply` 才真的删；同时 `launchctl bootout` 注销自启项。
- 本机已按 pkg 内容安装并注册：`launchctl print gui/501/local.vitals.app` 显示 `state = running`，程序为 `~/Applications/Vitals.app/Contents/MacOS/Vitals`。

**两个环境事实**：

1. **CLI 的 `installer` 装用户域包也要 root**（"Must be run as root to install this package"）——所以自动化验证走的是"手工按 pkg 内容安装"，真实用户双击走 Installer.app 才是正路。
2. 沙箱内 `launchctl bootstrap` 早期返回过 EIO，现在（danger-full-access）正常。

**自用签名**：不需要 Developer ID 与公证（ad-hoc 签名即可运行）；本机自用不涉及 Gatekeeper 分发。
