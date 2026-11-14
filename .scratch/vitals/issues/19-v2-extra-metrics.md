Type: task
Status: resolved
Blocked by: 10, 17

# v2：GPU / 磁盘 / 网络 / 进程 Top

## Question

在 v1 稳定之后，补齐剩余指标。

要交付：

- **GPU 占用百分比**：`AGXAcceleratorG18G` → `PerformanceStatistics` 的 `Device Utilization %`。**每 ~250 ms 整组掉 0** → 每次连读 3 次取最大；Device% 与 Renderer% 恒等；按 GLOSSARY 标**近似值**。
- **GPU 内存**：统一内存，**没有"显存"**。若要展示，用同节点的 `In use system memory`，界面命名用"GPU 占用系统内存"，不要叫显存。
- **磁盘吞吐**：`IOBlockStorageDriver` → `Statistics` 的累计计数器差分（30.26 µs）。要挑对盘——4 个节点里 2 个是磁盘映像；节点筛选规则见报告 §9（尚待定）。
- **网络吞吐**：`getifaddrs` + `if_data` 差分（24.33 µs）。`ifi_ibytes/obytes` 是 32 位、4 GiB 回绕（差分仍正确）；**必须排除 lo0** 与虚拟网卡。
- **速率换算陷阱**：`mach_absolute_time` 在本机**不是纳秒**（24 MHz），换算速率时不能当纳秒用。
- **进程 Top 列表**：libproc `proc_listpids` + `proc_pidinfo`（全量 0.889 ms，建议降到 2–3 s 一次）。**只读**、**只显示当前用户自己的进程**（libproc 天然如此，euid 过滤白送）、`kinfo_proc` 缓冲须 8 字节对齐、不可终止任何进程。
- **每进程 CPU% 是风险项**：`pti_total_user` 纳秒值连续差分不自洽、`p_cpticks` 不动。落地前必须验证；不稳就只显示 RSS + 进程名 + PID，并在界面上说明。
- 界面接入：悬浮窗内分区展示，曲线复用 60s 窗口；进程列表的刷新频率可低于指标采样（避免频繁重排）。
- 单元测试：速率计算、用户进程过滤。

**明确不做**：每进程磁盘 IO（`proc_pid_rusage` 对所有 pid 返回 0，V0/V1/V4 内核 abort）、绑核/affinity、`l2perflevels`、CPU/GPU 功耗 mW（需特权，而票 21 决定不引入特权组件）。

产出：实现 + 测试 + 验收勾选更新。

## Answer

**v2 指标已实现并在本机跑通**（`Sources/VitalsCore/Sampling/ExtendedSampling.swift` + 面板接入）：

| 指标 | 后端 | 实测 |
|---|---|---|
| GPU 占用 | `AGXAccelerator` → `PerformanceStatistics` 的 `Device Utilization %`，**连读 3 次取最大**（驱动每 ~250 ms 整组掉 0） | 0% 空闲；「占用系统内存」24 MB / 已划 9036 MB |
| 磁盘读写 | IOKit `IOBlockStorageDriver` → `Statistics` 累计计数器差分 | 首帧无基准显示「正在识别…」，第二帧起给出读/写 MB/s |
| 网络上下行 | `getifaddrs` + `if_data` 差分，**排除 lo0 与虚拟网卡**（utun/bridge/awdl…），选第一个 UP 的真实网卡 | en0，↓/↑ KB/s |
| 进程 Top 5 | libproc `proc_listpids` + `proc_pidinfo`，**天然只返回当前用户的进程**；按常驻内存排序 | DeepSeek Harness(550MB) / com.apple.WebKi(419MB) / Safari(222MB) … |

面板接入（按票 24 的分档表）：L1 加 GPU 占用瓦片，L2 加磁盘/网络瓦片，L4 加进程 Top 5 卡片。

**两个实现上的修正**：

1. **每进程 CPU% 不提供**（票 03 判定它不可靠：`pti_total_user` 纳秒值差分不自洽、`p_cpticks` 不动）→ 只显示进程名 + 常驻内存。宁可少一个数字，也不要给会骗人的数字。
2. macOS 27 的 `proc_bsdinfo` **没有 `pbi_rssize` 了**，常驻内存改从 `ptinfo.pti_resident_size` 取；进程名用 `pbsd.pbi_comm`（`proc_name` 对部分进程返回 0 长度，会显示成 "?"）。

**另一个命名撞车**：Foundation 已经有 `ProcessInfo` 类型（和之前的 `Measurement` 一样），本项目的进程行因此叫 **`ProcessRow`**。

进程列表**降频到 3 秒刷新一次**（全量扫描 0.889 ms，不必每秒做）。
