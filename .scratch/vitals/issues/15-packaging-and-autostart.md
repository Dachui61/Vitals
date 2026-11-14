Type: task
Status: open
Blocked by: 11, 14

# 安装包与开机自启

## Question

交付可双击安装的 `.pkg`，并让工具开机自启、可干净卸载。

要交付：

- `build.sh` 之后新增 `package.sh`：用 `pkgbuild`/`productbuild` 产出 `.pkg`，内含 `Vitals.app`（装到 /Applications）、可选的 helper LaunchDaemon 与 plist、LaunchAgent（用户级开机自启）。
- 安装体验：双击安装只需输入一次管理员密码；界面明确说明将安装什么（app、helper、开机自启）、以及 helper 是可选的（不装也能用，只是没有数值温度）。
- 卸载：卸载脚本移除 app、LaunchDaemon plist、LaunchAgent plist、socket 与日志；列出清理清单。
- **环境限制的处理**：本会话沙箱无法写 `~/Library/LaunchAgents` 与 `/Library/LaunchDaemons`，`launchctl bootstrap gui/$(id -u)` 在沙箱内返回 EIO——安装/卸载流程必须由用户在普通 Terminal 执行，因此脚本要：干跑检查（dry-run）、打印将要执行的命令、失败时给出可复制的手动步骤。
- 自用场景下是否需要 Developer ID 签名/公证的结论与理由（写进 README）。

产出：`package.sh` + 卸载脚本 + README 的安装/卸载章节。
