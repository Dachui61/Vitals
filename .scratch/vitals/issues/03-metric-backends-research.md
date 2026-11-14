Type: research
Status: open
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
