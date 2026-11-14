Label: wayfinder:map
Effort: vitals

## Destination

一台能在本机（Mac mini M6 / macOS 27）长期常驻的 macOS 监控工具「Vitals」：菜单栏图标 + 可拖拽的置顶悬浮窗，实时显示 CPU 总占用、每核曲线（按 超频/性能/能效 分组）、CPU 数值温度、内存、电源状态（v2 再加 GPU/磁盘/网络/进程 Top），中文界面，菜单栏迷你读数（CPU% + 温度 + 内存%），可配阈值告警；数值温度由自研的**可选**特权 helper 支撑；交付物是可双击安装的 .pkg，加上 docs/SPEC.md、GLOSSARY.md 与 docs/adr/。

## Notes

- 领域：macOS 系统级监控（个人自用工具）。每个会话先读 domain-modeling；涉及"该长什么样"用 prototype；需要拍板用 grilling。
- **平台事实（本机实测，已确认）**：macOS 27.0(26A425) / Apple M6 Mac mini (Mac18,5) / 12 核（2 超频 + 4 性能 + 6 能效）/ 16GB RAM / 仅交流电、无电池；只有 Xcode Command Line Tools（无完整 Xcode），`swiftc` 可直接编译并手工打包 .app（`LSUIElement=true` 即不进 Dock）。
- **可用数据源（无特权）**：`host_processor_info` 每核 CPU；`AGXAccelerator` → `PerformanceStatistics` 的 Device/Renderer/Tiler Utilization %（GPU 占用）；`ProcessInfo.thermalState` 四档热压力；pmset 电源状态。
- **不可用数据源（无特权）**：经典 SMC 读键路径已死（`AppleSMCUserClient` 在 macOS 27 不存在，`AppleSMCKeysEndpoint` 的读键一律 kIOReturnBadArgument）；`powermetrics` 必须 root；GPU 温度无任何公开路径；`IOPerformance.framework` 已从 macOS 27 的 dyld 缓存移除（IOReportHub 仍能无特权打开，私有协议待验证）。
- **已定的产品决策**：形态 = 菜单栏图标 + 点击展开的独立置顶 NSWindow；指标 = v1 CPU（总 + 每核 + 按核型分组）+ CPU 数值温度 + 内存 + 电源状态，v2 加 GPU/磁盘/网络/进程 Top；进程列表只读且只显示当前用户自己的进程；无特权做不到的部分才动用特权，helper 自研自建、可选安装、键名白名单 + 对端 uid 校验 + 审计日志；温度口径 = 主 CPU 温度（同时展示实测传感器名）；后端不可用时降级为 thermalState 四档，且**绝不编造 °C**；采样 1s、滚动窗口 60s、内存内保留 10 分钟历史；菜单栏读数 = CPU% + 温度 + 内存%；告警默认温度 80°C、CPU 持续 90% 超 30s、冷却 10 分钟、阈值可在菜单内改、可整体关闭；中文界面；只支持本机 Apple Silicon；不依赖任何第三方二进制。
- **工程约定**：SPM 多 target（VitalsCore / VitalsUI / VitalsHelper / VitalsApp / VitalsCoreTests）；采样层纯逻辑有单元测试；界面交互用手动验收清单验证；私有 IOKit API 只允许出现在温度模块内，且必须带能力探测 + 失败自动降级。
- **本 map 承载实现执行**：票可以是实现型 `task`，代码落地并通过对应验收项即视为 resolved。
- **交付与安装**：`build.sh` 产出 `.app`；另交付可双击安装的 `.pkg`（安装 LaunchDaemon 与开机自启 LaunchAgent，只输一次管理员密码）+ 卸载脚本。安装/卸载需在用户 Terminal 执行——本会话沙箱无法写 `~/Library/LaunchAgents` 与 `/Library/LaunchDaemons`，且 `launchctl bootstrap` 在沙箱内返回 EIO，须在普通终端复核。
- **事实报告**：`research/macos-m6-temperature-feasibility.md`（分支 `research/temperature-feasibility`）。

## Decisions so far

<!-- 图表阶段为空：每关闭一张票，在此追加一行（gist + 链接）。 -->

## Not yet specified

- 温度后端落地后，降级链在界面上的具体文案与色带（等「温度后端选型与降级契约」）
- 特权 helper 的 socket 协议细节：请求/响应格式、缓存策略、超时与重连（等「特权 helper」）
- 磁盘/网络吞吐的采样实现方式：libproc 增量 vs 每秒派生子进程，及其实测开销（等「指标采集后端实测」）
- 进程 Top 列表中"当前用户进程"的判定口径与刷新开销（等「指标采集后端实测」）
- 自用 .pkg 是否需要 Developer ID 签名与公证（等「安装与分发」）
- 浮窗默认位置、是否记忆上次位置、跨显示器移动的行为（等「悬浮窗视觉原型」）
- 历史数据是否需要落盘或导出（当前仅在内存，未定）

## Out of scope

- Intel Mac 兼容：只支持本机 Apple Silicon（经典 SMC 路径在本机已死）
- 电池与耗电指标：本机为 Mac mini、仅交流电；改为"电源状态"展示
- GPU 温度：macOS 27 上没有任何公开或可达路径
- dmg 分发与 Developer ID 公证：改为本机 .pkg 双击安装
- 远程监控与告警外发：仅本机通知
- 第三方温度/监控工具集成：不依赖第三方二进制
