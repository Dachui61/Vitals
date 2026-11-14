Type: task
Status: open
Blocked by: none

# 项目骨架与构建打包

## Question

建立 SPM 多 target 工程骨架，并让 `build.sh` 一次产出可双击运行的 `.app`。

要交付：

- `Package.swift`：`VitalsCore`（采样与模型，无 UI 依赖）、`VitalsUI`（SwiftUI 视图）、`VitalsHelper`（特权 helper 可执行）、`VitalsApp`（app 壳）、`VitalsCoreTests`。
- `build.sh`：`swiftc`/`swift build` 编译 → 手工组装 `Vitals.app`（Contents/MacOS + Info.plist：`CFBundleIdentifier`、`CFBundleExecutable`、`CFBundlePackageType=APPL`、`LSMinimumSystemVersion=13.0`、`LSUIElement=true`）→ ad-hoc 签名 → 验证 `lsappinfo` 显示 `type="UIElement"`（不进 Dock）。
- **构建约束**（本机沙箱实测）：`swiftc` 必须带 `-module-cache-path "$PWD/.modulecache" -Xcc -fmodules-cache-path="$PWD/.modulecache"`，否则默认 `$TMPDIR` 缓存不可写；`@main` 必须加 `-parse-as-library`。
- 目录结构：Sources/、Tests/、Scripts/、docs/、.gitignore（忽略 .build/、.modulecache/、scratch/）。
- 验证：在本机编译出可启动的空壳 app（至少有一个菜单栏图标 + 一个占位浮窗），并把启动/退出步骤写进 README。

产出：可运行的骨架 + 构建脚本 + README 使用说明。
