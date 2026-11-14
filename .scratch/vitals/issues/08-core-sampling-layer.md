Type: task
Status: open
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
- **单元测试**（`VitalsCoreTests`）：CPU 差分算法（已知序列 → 已知百分比）、平滑（ma3，不是 EMA——EMA 滞后会让告警误触发）、环形缓冲、速率计算、百分比与温度格式化边界（不可用/负值/NaN）、核型映射（E/P/M → 中文名与分组）。
- 告警用的应是**原始值**，不是平滑值。

约束：采样层不 import SwiftUI，不碰 UIKit/AppKit；**不得 fork 子进程**取数（实测 fork `iostat` 1075 ms、`pmset` 76 ms，1 Hz 完全不可接受）。

产出：实现代码 + 测试 + 每个采集后端的一页说明（数据来源、刷新代价、已知坑）。
