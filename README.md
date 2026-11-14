# Vitals

一个 macOS 菜单栏 + 悬浮窗的电脑健康监控工具：实时显示 CPU 占用（总量与每核，按核型着色）、CPU 核心温度、SoC 热点、内存、电源状态（v2 再加 GPU / 磁盘 / 网络 / 进程 Top 5）。

> 状态：**开发中**。当前只有工程骨架 —— 菜单栏图标 + 占位悬浮窗；真实采样、完整面板、告警、安装包分别由 `.scratch/vitals/issues/` 里的票驱动。

## 构建与运行

```bash
./scripts/build.sh          # 构建 build/Vitals.app（可双击运行）
./scripts/build.sh run      # 构建 + 启动
./scripts/build.sh verify   # 构建 + 启动 + 验证它进了菜单栏且不进 Dock
./scripts/test.sh           # 跑测试
```

构建产物：`build/Vitals.app`（`LSUIElement=true`，所以只出现在菜单栏，不进 Dock）。

## 工程结构

```
Package.swift              SPM 多 target
Sources/
  VitalsCore/              采样与数据模型（不依赖任何 UI 框架）
    Metric.swift           读数类型：值 + 可信度 + 传感器名 / 不可用 + 原因
    Models.swift           CPU、内存、温度、电源、热压力的模型
    Providers.swift        provider 协议（票 08/09 实现）
    Formatting.swift       数值格式化（界面与测试共用）
  VitalsUI/                SwiftUI 视图层（只依赖 VitalsCore）
  VitalsApp/               App 壳：菜单栏图标 + 无边框悬浮窗
Tests/VitalsCoreTests/     测试（零依赖断言运行器，见下）
scripts/                   build.sh / test.sh / package.sh(票 15) / frontier.sh
prototypes/                悬浮窗原型（视觉与响应式分级的依据）
docs/                      SPEC.md(票 17)、adr/、acceptance.md(票 07)
research/                  各项实测报告（分支 research/*）
.scratch/vitals/           wayfinder 地图与票据
```

## 这台机器上的构建约束

- **只有 Xcode Command Line Tools**（没有完整 Xcode），所以 `.app` 是手工组装的：编译 → 拷贝可执行文件 → 写 `Info.plist` → ad-hoc 签名。
- **没有 XCTest，也没有 swift-testing**（工具链里都没有），所以测试是一个零依赖的可执行目标 `VitalsCoreTests`，用 `test()/expect()/expectEqual()` 断言，`scripts/test.sh` 跑它，退出码即成败。
- `swift build` 的产物目录用 `swift build --show-bin-path` 取，不要写死 `.build/release`。
- 直接用 `swiftc` 编译时必须给 `-module-cache-path`（默认缓存在 `$TMPDIR`，这里不可写），`@main` 要配 `-parse-as-library`。
- 命名注意：Foundation 已经有 `Measurement<Unit>`，本项目的读数类型叫 **`Metric<Value>`**。
- 写 shell 脚本时，**变量后面紧跟中文全角括号会被 bash 当成变量名的一部分**（`$CONFIG）` → 未定义变量），要用 `${CONFIG}`。

## 开发路线图

`.scratch/vitals/map.md` 是总图，`./scripts/frontier.sh` 列出当前可动手的票。已定的产品决策都在地图的 Notes 与 Decisions so far 里。
