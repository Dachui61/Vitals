Type: task
Status: resolved
Blocked by: 06, 08

# 采样调度与状态流

## Question

实现"每秒采一次、UI 随时可读"的调度与状态分发。

要交付：

- 采样引擎：以 actor（或等价并发结构）持有采样状态，1s 定时 tick；UI 只读取快照，不直接触发采集。
- 历史缓冲：每指标保留 60s 滚动窗口用于曲线，另保留 10 分钟的粗粒度历史（内存内，重启清空），写入策略与内存上限明确。
- 后端失败的处理：某个 provider 失败只影响该指标，其他指标继续；连续失败要退避，不能 1s 重试打爆 CPU。
- 状态分发：把快照发布给菜单栏迷你读数、浮窗、告警三处（SwiftUI 的 Observation 或 Combine，选定后全项目统一）。
- 生命周期：app 启动即开始采样，退出/睡眠唤醒/显示器休眠时的行为（唤醒后立即补一次采样，避免显示陈旧值）。
- 单元测试：tick 驱动的时序、退避逻辑、环形缓冲边界。

产出：实现 + 测试；并在 README 记录"多久刷新一次、在哪里改"。

## Answer

**调度与状态流已实现**：`MetricsEngine`（`Sources/VitalsCore/Sampling/MetricsEngine.swift`）。

- 1 Hz `Timer` 挂在主 RunLoop 的 `.common` 模式（睡眠/菜单跟踪时也能继续）。
- 启动即采一帧，之后每秒一帧；UI 通过 `onUpdate` 回调拿快照，**不触发采集**。
- 每帧产出 `CoreSnapshot`（CPU / 内存 / 电源 / 核心温度 / SoC 热点 / 热压力），任何一项失败只影响它自己。
- 历史：`HistoryStore` 维护每核 60 秒曲线（60 点）+ 10 分钟粗粒度（每 10 秒一点，60 点），全在内存，重启清空。
- 平滑用 3 点滑动平均（**不用 EMA**：滞后会让告警误触发），告警判定用原始值。
- 温度不可用时后台跑惰性探测，期间该项显示「正在识别…」。

**一个必须记住的坑**：live 检查里如果用 `Thread.sleep` 等 tick，会占住主线程让 Timer 根本没机会触发（表现为 CPU 永远"正在识别…"）。正确写法是 `RunLoop.current.run(until: Date().addingTimeInterval(1))`。

**注意**：`MetricsEngine` 目前是"等价并发结构"（Timer + NSLock）而非 actor —— 因为项目现在跑在 Swift 5 语言模式（严格并发下 `Metric<Value>` 的条件一致性会有告警）。升级到 v6 模式时再改成 actor，届时记在地图的雾区。
