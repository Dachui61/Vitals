Type: task
Status: resolved
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

## Answer

**骨架已建成并在本机跑通**：`build/Vitals.app` 能双击运行，菜单栏出现 Vitals 图标，`lsappinfo` 确认 `type="UIElement"`（不进 Dock），悬浮窗可拖动/缩放。

**结构**（SPM 多 target，`swift build` 直接可用）：

- `VitalsCore` —— 采样与模型，**不依赖任何 UI 框架**：`Metric<Value>`（值 + 可信度 + 传感器名 / 不可用 + 原因）、`CPULoad`/`MemoryUsage`/`PowerState`/`TemperatureReading`/`ThermalState`、`CoreSnapshot`、provider 协议、`VitalsFormat` 格式化。
- `VitalsUI` —— SwiftUI 视图层，只依赖 `VitalsCore`：`VitalsTheme`（跟随系统浅/深 + 背景透明度，文字恒不透明）、`MetricTile`、`PlaceholderPanel`。
- `VitalsApp` —— App 壳：`NSStatusItem` 菜单栏图标 + 无边框可拖可缩的置顶悬浮窗。
- `Tests/VitalsCoreTests` —— 测试。

**三个必须写进后续票据的环境事实**：

1. **本机既没有 XCTest 也没有 swift-testing**（工具链里都不存在，`swift test` 直接报 "unable to resolve module dependency: 'XCTest'"）。所以测试改成**零依赖的可执行目标**：`test()/expect()/expectEqual()/expectClose()` 断言 + `scripts/test.sh`，退出码即成败。票 07/08 的"单元测试"就按这个形式来。
2. **Foundation 已经有 `Measurement<Unit>`**，本项目的读数类型因此叫 **`Metric<Value>`**（且需要 `extension Metric: Equatable where Value: Equatable` / `Sendable where Value: Sendable` 两条条件一致性）。
3. **悬浮窗的默认位置有两个坑**：压 Dock（要用 `NSScreen.visibleFrame` 内缩，而不是硬编码坐标），以及 macOS 桌面小组件画在**左上角**且层级高于 `.floating` 窗口——所以默认位置别放在左上。

**其它**：`Package.swift` 目前用 `swiftLanguageModes: [.v5]`（Swift 6 严格并发下 `Metric<Value>` 的 Sendable 条件一致性会有告警，改到 v6 模式是后续项）；`scripts/build.sh` 负责编译 → 组装 `.app` → 写 `Info.plist`（`LSUIElement=true`）→ ad-hoc 签名 → `verify` 模式用 `lsappinfo` 验证；`swift build` 的产物路径要用 `swift build --show-bin-path` 取，不要写死。

产出：`build/Vitals.app` 可直接双击运行；README 记录了构建、运行、测试与本机约束。
