Type: research
Status: resolved
Blocked by: none

# 各指标的采集后端与实测开销

## Question

在 macOS 27 / Apple M6 上，每个指标该用哪个后端、1s 采样一次的开销多大？逐项给出结论（推荐 API + 实测开销 + 备选方案）：

- **CPU 总量与每核**：`host_processor_info`（PROCESSOR_CPU_LOAD_INFO）与 `host_statistics` 的取舍；12 核下每 1s 调用的耗时；`TH_CPU_SCALE=1000` 下的两次采样差分算法与平滑方式；`hw.perflevel0/1`（本机 2 超频 + 4 性能 + 6 能效）能否区分核型并映射到逻辑核。
- **内存**：已用/总量、内存压力等级、压缩内存、swap 的权威来源与 API。
- **GPU 占用**：`AGXAccelerator` → `PerformanceStatistics` 的 Device/Renderer/Tiler Utilization % 读取稳定性（同一秒两次读是否一致、是否有多个 AGX 节点、要不要取平均）；1s 采样开销；统一内存/显存占用如何展示才有意义。
- **磁盘吞吐**：无 fork 的方案（`getdirentries` / `IOBlockStorageDriverStatistics` / libproc）与"每秒派生子进程跑 iostat"的对比实测。
- **网络吞吐**：`getifaddrs` 增量 vs 派生子进程跑 netstat；如何排除 loopback 与虚拟接口。
- **进程 Top**：`sysctl KERN_PROC_ALL` vs libproc `proc_listpids`/`proc_pidinfo`；"当前用户进程"判定（euid）；刷新开销；是否需要 rss/cpu 时间字段。
- **电源状态**：无电池的 Mac mini 上 pmset / IOPowerSources 的表现与可展示字段。

产出：`research/metric-backends.md`——每指标一节，含推荐 API、实测数字、备选与坑；本票以该文件作为答案。

## Answer

**结论：v1 全部指标都能无特权采集，1 Hz 全量采样实测约 11.8 µs（占采样周期 0.0012%）。** 下面是选定后端与必须避开的坑。

| 指标 | 后端 | 需特权 | 实测开销 | 坑 |
|---|---|---|---|---|
| CPU 总量 + 每核 | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | 否 | 8.23 µs | 返回数组由内核分配，**必须 `vm_deallocate`**，否则每秒漏 384 B；**tick 比例实测 100/s 不是 1000/s**（票面假设有误） |
| CPU 总量（只要总量） | `host_statistics(HOST_CPU_LOAD_INFO)` | 否 | 0.89 µs | 只有聚合值 |
| 核型 | 设备树 `IODeviceTree:/cpus/cpuN@N` 的 `cluster-type` | 否 | 启动读一次 | `hw.perflevelN` 只给数量不给下标；`l2perflevels` 本机不存在；`THREAD_AFFINITY_POLICY` 返回 46 不支持；设备树节点不在 service plane |
| 内存 | `host_statistics64(HOST_VM_INFO64)` | 否 | 0.58 µs | "已用"要自己拼；macOS 27 新增字段语义不同 |
| 内存压力 | `sysctl kern.memorystatus_vm_pressure_level` | 否 | ~0.6 µs | 位掩码 1/2/4 |
| Swap | `sysctl vm.swapusage` | 否 | 0.61 µs | `xsu_*` 单位是字节不是页 |
| GPU 占用 | `AGXAcceleratorG18G` → `PerformanceStatistics` 的 `Device Utilization %` | 否 | 18.95 µs | **每 ~250 ms 整组掉 0**；Device% 与 Renderer% 恒等；`IOServiceOpen` 被拒 |
| GPU 内存 | 同上的 `In use system memory` | 否 | 同上 | **统一内存，没有"显存"**，必须改名 |
| 磁盘速率 | IOKit `IOBlockStorageDriver` → `Statistics` | 否 | 30.26 µs（4 节点） | 累计计数器要差分；4 个节点里 2 个是磁盘映像 |
| 网络速率 | `getifaddrs` + `if_data` 差分 | 否 | 24.33 µs | `ifi_*` 是 32 位、4 GiB 回绕（差分仍对）；要排除 loopback 与虚拟网卡 |
| 进程 Top | libproc `proc_listpids` + `proc_pidinfo` | 否 | 全量 0.889 ms | **天然只返回当前用户的进程**（与既定口径一致，euid 过滤白送）；`kinfo_proc` 缓冲须 8 字节对齐 |
| 电源状态 | `AppleSmartBattery` 的 `BatteryInstalled`/`ExternalConnected` | 否 | 2.42 µs | `IOPSCopyPowerSourcesInfo()` 非 nil 但电源列表为空；fork `pmset` 要 76 ms |

**核型映射（本票最难的一块，已确定）**：设备树 `cluster-type` 是唯一能给逻辑核下标的源 —— **0–5 = E = 能效核（6 个）、6–7 = P = 超频核/Super（2 个）、8–11 = M = 性能核（4 个）**。推导依据是"数量唯一配对"（E 6↔Efficiency 6，余下 P 2↔Super 2、M 4↔Performance 4），并由 L2 拓扑佐证（P 与 M 的 6 个核 `l2-cache-id` 同域、`l2-cache-size`=0x4001，6 个 E 核是另一个域 0x8000），正对应 `sharesl2`（Super 与 Performance 共享 L2、Efficiency 独占）。**不要用基准测试区分 P 与 M**（只差 1–3%，分不开）。

**其它必须记住的坑**：

- 内存"已用"口径 = `(active_internal + inactive_internal − purgeable) + wire + compressed`（= App + Wired + Compressed，本机 10.16/16 GiB）。**不要用 `total − free − speculative`**（那是 15.6 GiB，把 file-backed 也算进去了）。
- CPU 差分 = (Δuser+Δsys+Δnice)/总，idle 之外都算忙；平滑用 ma3（EMA 滞后会让告警误触发），**告警判定用原始值**。
- GPU 每次连读 3 次取最大，对抗周期性掉 0；按 GLOSSARY 标近似值。
- 磁盘/网络都用累计计数器差分；网络**必须排除 lo0**（否则 24 GB 背景流量淹没真实值）。
- 电源别 fork `pmset`（76 ms），直接读 `AppleSmartBattery` 两个属性。
- `mach_absolute_time` 在本机**不是纳秒**（24 MHz），换算速率时不能当纳秒用。

**v1 / v2 / 放弃**：

- **v1 可上**：CPU 总量 + 每核（含核型分组）、内存、内存压力、swap、电源状态、热压力等级。
- **v2**：GPU 占用、GPU 内存（改名"GPU 占用系统内存"）、网络速率、磁盘速率、进程 Top。
- **放弃**：「显存占用」这一说法（改名）、每进程磁盘 IO（`proc_pid_rusage` 对所有 pid 返回 0，V0/V1/V4 内核 abort）、绑核（affinity）、`l2perflevels`。
- **功耗 mW 需要特权**——但票 21 已决定不引入特权组件，所以这一项随之出局。

**风险项**：**每进程 CPU% 不可靠**（`pti_total_user` 纳秒值连续差分不自洽、`p_cpticks` 不动）。落地前必须验证；不稳就只显示 RSS + 进程名 + PID。

可复用实现：`scratch/VitalsMetrics.swift`（可编译、带 @main 自测）；探针与原始输出在 `scratch/`。

完整报告：[research/metric-backends.md](../../research/metric-backends.md)（分支 `research/metric-backends`）
