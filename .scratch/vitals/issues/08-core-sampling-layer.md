Type: task
Status: resolved
Blocked by: 03, 06, 07

# 核心采样层实现与单元测试

## Question

在 `VitalsCore` 里实现 v1 各项指标的真实采集，并让纯逻辑部分有单元测试。

范围（后端与坑由票 03 实测定稿，以下直接照做）：

- **CPU**：`host_processor_info(PROCESSOR_CPU_LOAD_INFO)`（8.23 µs）。返回的扁平数组每核 4 个 natural_t（user/sys/idle/nice），**必须 `vm_deallocate`**，否则每秒泄漏 384 B。**tick 比例实测 100/s（不是 1000/s）**——百分比不受影响，但换算 CPU 秒必须按 100 标定。差分口径 = (Δuser+Δsys+Δnice)/总，idle 之外都算忙。
- **核型**：启动时读一次设备树 `IODeviceTree:/cpus/cpuN@N` 的 `cluster-type`（CFData）：**E → 能效核、P → 超频核(Super)、M → 性能核(Performance)**。本机映射 0–5 能效、6–7 超频、8–11 性能。注意设备树节点不在 service plane，要用 `IORegistryEntryCreateIterator` 从 `IODeviceTree:/cpus` 遍历；`hw.perflevelN` 只给数量不给下标，不要依赖。
- **内存**：`host_statistics64(HOST_VM_INFO64)`。已用 = `(active_internal + inactive_internal − purgeable) + wire + compressed`（= App+Wired+Compressed，本机 10.16/16 GiB）。**不要用 `total − free − speculative`**（那是 15.6 GiB，把 file-backed 也算进去了）。macOS 27 有新增字段，语义与旧字段不同。
- **内存压力**：`sysctl kern.memorystatus_vm_pressure_level`（位掩码 1/2/4）。
- **Swap**：`sysctl vm.swapusage`（`xsu_*` 单位是**字节**，别再乘 pagesize）。
- **电源状态**：`AppleSmartBattery` 的 `BatteryInstalled` / `ExternalConnected`（2.42 µs）。不要 fork `pmset`（76 ms）。本机无电池，界面只显示供电状态。
- **热压力等级**：`ProcessInfo.thermalState` + `thermalStateDidChangeNotification`。
- **GPU 占用**（接口先做好，UI 后接）：`AGXAcceleratorG18G` → `PerformanceStatistics` 的 `Device Utilization %`（18.95 µs）。**每 ~250 ms 会整组掉 0** → 每次连读 3 次取最大；Device% 与 Renderer% 恒等。**统一内存，没有"显存"**，若要显示内存则用同节点的 `In use system memory`，命名按"GPU 占用系统内存"。
- 采样器抽象：每个指标一个 provider 协议，失败时返回"不可用 + 原因"而不是抛异常或编造数值；便于单测注入假数据。
- **单元测试**（`Tests/VitalsCoreTests`，用票 06 定下的零依赖断言运行器：`test()` / `expect()` / `expectEqual()` / `expectClose()`，由 `scripts/test.sh` 跑，退出码即成败；**本机没有 XCTest 也没有 swift-testing**）：CPU 差分算法（已知序列 → 已知百分比）、平滑（ma3，不是 EMA——EMA 滞后会让告警误触发）、环形缓冲、速率计算、百分比与温度格式化边界（不可用/负值/NaN）、核型映射（E/P/M → 中文名与分组）。
- 告警用的应是**原始值**，不是平滑值。

约束：采样层不 import SwiftUI，不碰 UIKit/AppKit；**不得 fork 子进程**取数（实测 fork `iostat` 1075 ms、`pmset` 76 ms，1 Hz 完全不可接受）。

产出：实现代码 + 测试 + 每个采集后端的一页说明（数据来源、刷新代价、已知坑）。

## Answer

**核心采样层已实现并在本机跑通**（真机读数见下方 live 检查输出）。24 个单元测试全过。

实现（`Sources/VitalsCore/Sampling/`）：

- `CPUSampling.swift` —— `MachCPUSampler`（`host_processor_info`，**必须 `vm_deallocate`**）、`CPUBusyCalculator`（纯逻辑）、`CPUBusyTracker`（维护差分基准）、`CPUProviderImpl`。
- `CoreTopology.swift` —— 设备树 `cluster-type` → 核型映射（数量唯一配对），**匹配不上就返回 nil → 不分组，绝不猜**。
- `MemorySampling.swift` —— 内存 + 内存压力 + swap。
- `PowerSampling.swift` —— `AppleSmartBattery` 供电状态 + `ProcessInfo.thermalState`。
- `SMCSession.swift` / `TemperatureSampling.swift` —— 温度后端（见票 09）。
- `History.swift` —— `RingBuffer`、`MovingAverage3`、`HistoryStore`（60 秒曲线 + 10 分钟粗粒度）。
- `MetricsEngine.swift` —— 1 Hz tick，产出快照 + 历史。

### ⚠️ 内存口径修正（票 03 的结论要改）

票 03 报的"已用 = (active_internal + inactive_internal − purgeable) + wire + compressed = 10.16/16 GiB"**是错的**，两个原因叠加：

1. **`host_statistics64` 返回的长度不可靠**：同一个二进制里，独立编译的进程拿到 104 个 4 字节整数（正好填满 416 字节的 `vm_statistics64`），而 **SwiftPM 构建出来的进程只拿到 40 个**（160 字节）——结构体后半段（`external_page_count` / `internal_page_count` / `active_internal_count` / `inactive_internal_count`）全是 0。照返回长度拷贝会**静默少读一大半字段**。
2. 即使字段都读到了，`active_internal` / `inactive_internal` 也是"内部页"，不是活动监视器口径。

本机实测对照（`vm_stat` 逐项确认 + `top -l 1` 交叉验证）：

- **已用内存 = (active + inactive − purgeable) + wired + compressed = 14.6 / 16.0 GB**，与 `top` 的 `PhysMem: 15G used` 一致（top 取整）。
- 与**活动监视器的「Memory Used」（约 10 GB）不是同一个口径** —— 后者不含 file-backed。菜单栏与悬浮窗显示的是前者（系统"正在被用掉的物理内存"）。
- 现在实现**只用经验验证过的原始整数下标**（active=1、inactive=2、wired=3、purgeable=22、speculative=23、compressor=32），并对每个值做"不超过总页数"的合理性校验；校验不过就报「不可用」，不显示 0。
- 修之前应用显示 4.9 GB（错），修之后 14.6 GB（对）。

### 真机读数（live 检查）

```
核型映射: 超频核=6,7  性能核=8,9,10,11  能效核=0,1,2,3,4,5
CPU: 总 0.9%  每核 5/3/2/0/0/0/1/0/0/0/0/0
核心温度: 42.2 °C  来源 SMC Tp0j  可信度 近似值
SoC 热点: 50.3 °C (SMC TVD0)
内存: 14.7 / 16.0 GB (92%)  压力 正常  swap 7073 MB
电源: 外接电源
热压力等级: 正常
```

单元测试（`scripts/test.sh`，24 个用例）覆盖：CPU 差分（idle 之外算忙、nice 算忙、**计数回绕判为不可比**、核数不一致不可比）、tick 比例 100/s、环形缓冲淘汰、3 点滑动平均、历史窗口与粗粒度、内存百分比、温度合理区间、降级链不含被禁用的键族、核型排序。

**可复用的验证手段**：`VITALS_LIVE=1` 运行测试二进制会做一次真机采样并打印实际读数 —— 比"编译通过"有力得多。
