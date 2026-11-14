# 各指标的采集后端与实测开销

> 票 03 · research · 实测机器：macOS 27.0 (26A425) / Apple M6 Mac mini (Mac18,5) / 12 核 (2 超频 + 4 性能 + 6 能效) / 16 GB RAM / 仅交流电
> 实测时间：2026-11-14 20:31–21:02 (Asia/Shanghai)
> 全部测量在**无特权**（uid=euid=501）沙箱内完成；未使用 sudo。
> 可复用代码：`scratch/VitalsMetrics.swift`（可编译、带自测入口）、`scratch/probe_*.swift`（探针）
> 原始输出：`scratch/out_*.txt`

术语按 `GLOSSARY.md`：**CPU 占用**、**核型**、**热压力等级**、**近似值**、**不可用**、**后端**、**降级链**、**特权组件**。

---

## 摘要表

| 指标 | 推荐后端 | 需特权 | 单次开销（实测） | 主要坑 |
|---|---|---|---|---|
| CPU 总量 + 每核 | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | 否 | **8.23 µs** avg / 5.83 min / 53.08 max | 返回的数组由内核分配，**必须 `vm_deallocate`**，否则每秒泄漏 384 B；**tick 比例是 100/s 不是 1000/s**（票面假设有误） |
| CPU 总量（只要总量） | `host_statistics(HOST_CPU_LOAD_INFO)` | 否 | **0.89 µs** avg | 只有聚合值，给不出每核；与每核求和**逐 tick 相等** |
| 核型（超频/性能/能效） | IODeviceTree `cpus/cpuN@N` 的 `cluster-type` | 否 | 启动时读一次（≈µs 级） | `hw.perflevelN` 只给**数量**不给**下标**；`hw.perflevelN.l2perflevels`（SDK 有文档）本机**不存在**；`THREAD_AFFINITY_POLICY` 返回 **46 不支持**；`host_processor_sets` 返回 **4 无效**；设备树节点不在 service plane 里 |
| 内存（已用/总量） | `host_statistics64(HOST_VM_INFO64)` | 否 | **0.58 µs** avg | “已用”口径要自己拼（App+Wired+Compressed）；macOS 27 新增字段与旧字段**语义不同** |
| 内存压力等级 | `sysctl kern.memorystatus_vm_pressure_level` | 否 | ≈ 0.6 µs | 值是位掩码（1=normal / 2=warn / 4=critical） |
| Swap | `sysctl vm.swapusage` | 否 | **0.61 µs** avg | `xsu_total/avail/used` 单位是**字节**不是页；`xsu_pagesize` 别再乘一遍 |
| GPU 占用 | `AGXAcceleratorG18G` → `PerformanceStatistics` 的 `Device Utilization %` | 否 | **18.95 µs** avg | **每 ~250 ms 会整组掉到 0**；Device % 与 Renderer % 恒等；`IOServiceOpen` 被拒（`kIOReturnNotPrivileged`） |
| GPU 内存 | 同上的 `In use system memory` | 否 | 同上 | **没有 “显存”这回事**（统一内存）；必须改名重定义 |
| 磁盘读写速率 | IOKit `IOBlockStorageDriver` → `Statistics` | 否 | **30.26 µs** avg（4 个节点） | 累计计数器，要自己做差分；4 个节点里 2 个是磁盘映像，要挑对盘 |
| 网络吞吐 | `getifaddrs` + `if_data` 差分 | 否 | **24.33 µs** avg | `ifi_ibytes/obytes` 是 **32 位**，4 GiB 回绕（差分仍正确）；要自己排除 loopback 与虚拟网卡 |
| 进程 Top | libproc `proc_listpids` + `proc_pidinfo` | 否 | 全量扫描 **0.889 ms** | libproc **只返回当前用户的进程**（别人的直接失败），euid 过滤天然免费；`kinfo_proc` 缓冲区必须 8 字节对齐 |
| 电源状态 | `AppleSmartBattery` 的 `BatteryInstalled` / `ExternalConnected` | 否 | **2.42 µs** avg | `IOPSCopyPowerSourcesInfo()` 返回非 nil 但**电源列表为空**；`pmset -g ps` 要 fork（76 ms） |
| 功耗（mW） | `powermetrics --samplers cpu_power` | **是** | — | 无特权拿不到任何瓦数；`ApplePMPv2` 节点可见但要开 user client（root） |
| 每进程磁盘 IO | ✗ 无 | — | — | `proc_pid_rusage` 对**所有** pid（含自己的、含 launchd）返回 0；V0/V1/V4 直接在内核里 abort |

**1 Hz 全量采样的实测总开销（v1 全套）**：CPU 8.23 + 内存 0.58 + swap 0.61 + 电源 2.42 ≈ **11.8 µs/次**，相对 1 s 采样周期是 0.0012%。
加满 v2（GPU 18.95 + 网络 24.33 + 磁盘 30.26 + 进程全量扫描 889 µs）≈ **0.96 ms/次**，仍可接受，但进程列表建议降到 2–3 s 一次。

---

## 1. CPU 总量与每核

### 1.1 `host_processor_info` vs `host_statistics`

`host_processor_info` 返回的是**扁平数组**：`processor_info_array_t` 实际是 `integer_t *`，每核 4 个 natural_t（user / sys / idle / nice），本机 12 核 → 48 个 natural_t。Swift 里必须重解释：

```swift
// scratch/probe_cpu.swift
func readProcessorInfo() -> ProcInfo {
    var cnt = mach_msg_type_number_t(0)
    var arr: processor_info_array_t? = nil
    var acnt = mach_msg_type_number_t(0)
    let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cnt, &arr, &acnt)
    guard kr == KERN_SUCCESS, let arr = arr else { return ProcInfo() }
    var pi = ProcInfo()
    pi.count = Int(cnt)
    for i in 0..<Int(cnt) {
        // processor_info_array_t 是 integer_t*，要按 processor_cpu_load_info 重解释
        let p = UnsafeMutableRawPointer(arr)
            .advanced(by: i * MemoryLayout<processor_cpu_load_info>.size)
            .assumingMemoryBound(to: processor_cpu_load_info.self)
        pi.ticks.append([p.pointee.cpu_ticks.0, p.pointee.cpu_ticks.1,
                         p.pointee.cpu_ticks.2, p.pointee.cpu_ticks.3])
    }
    // 内核分配、调用方负责释放：不释放的话每秒泄漏 48*8 = 384 字节
    vm_deallocate(mach_task_self_, vm_address_t(bitPattern: arr),
                  vm_size_t(acnt) * vm_size_t(MemoryLayout<natural_t>.size))
    return pi
}
```

Swift 参数顺序与 C 不同：`host_processor_info(host, flavor, &count, &array, &cnt)`。

`host_statistics(HOST_CPU_LOAD_INFO)` 便宜 9 倍但**只有聚合值**。实测两者完全一致：

```
  logical CPUs reported by host_processor_info = 12
  flat array natural_t count = 48
    core  0: user=  2985387 sys=  1709121 idle= 17898098 nice=        0
    ...
  host_statistics(HOST_CPU_LOAD_INFO): user=16890656 sys=7167795 idle=248908851 nice=0
  sum(per-core user) = 16890656  vs host_statistics user = 16890656
  sum(per-core idle) = 248908851  vs host_statistics idle = 248908851
```

**开销（1000 次迭代，`scratch/out_cpu.txt`）**

```
  host_processor_info(+vm_deallocate) avg=   8.226 us  min=   5.834 us  max=   53.084 us  p50=   7.334 us
  host_processor_info(no free)       avg=   5.418 us  min=   3.709 us  max=   65.958 us  p50=   4.834 us
  host_statistics(HOST_CPU_LOAD_INFO) avg=   0.889 us  min=   0.792 us  max=    3.667 us  p50=   0.875 us
  sysctlbyname(hw.ncpu)              avg=   0.902 us  min=   0.792 us  max=    6.416 us  p50=   0.875 us
```

**结论**：v1 要每核曲线，就用 `host_processor_info`（8.2 µs 完全无所谓）。菜单栏那个“CPU%”若只要总量，用 `host_statistics`（0.89 µs）——但同一次采样里反正已经调了 `host_processor_info`，直接求和即可，不必再调一次。

### 1.2 ⚠️ tick 比例是 100/s，不是 1000/s

票面写“`TH_CPU_SCALE` 不暴露，按 1000 处理”。**本机实测是 100/s（1 tick = 10 ms）**，不是 1000。

证据一：连续 10 s 内 12 核全部计数器的增量（`scratch/out_tickscale2.txt`）：

```
  sleep(10): wall(Date) = 10.0009 s | mach_absolute_time = 0.2400 s | CLOCK_MONOTONIC_RAW = 10.0008 s
  total tick delta (all cores, all 4 counters) = 11960
  idle tick delta  = 9451, busy tick delta = 2509
  => per-core tick rate (total/(wall*ncpu)) = 99.7 ticks/s   -> implied TH_CPU_SCALE = 100
```

证据二：把一个线程钉在单核上死循环 10.00 s，那个核的 user tick 增量（`scratch/out_spin.txt`）：

```
    core  6: user=   975 sys=    21 idle=     3
    core  7: user=   979 sys=    16 idle=     4
  busiest core = 7 with 979 user ticks over 10.00 s
  => implied TH_CPU_SCALE = 98 ticks/s (if that core was 100% user-busy)
```

**为什么坑**：百分比是**比值**，与比例无关，所以“CPU 占用 %”不受影响；但**任何把 tick 换算成 CPU 秒**的地方（每进程 CPU%、每核 CPU 秒、告警阈值里的“持续占用”）都会差 10 倍。
**结论：百分比随便算，换算成秒必须自己标定（本机 100/s）。**

顺带一个同源陷阱：**本机 `mach_absolute_time()` 不是纳秒**（10 s 墙钟只前进 0.24 s，即 24 MHz 时间基）。用它测速会错 41.67 倍。测速统一用 `clock_gettime(CLOCK_MONOTONIC_RAW)` 或 `DispatchTime`。

### 1.3 两次采样差分算法

idle 是唯一“占满核”的计数器，所以：

```
busy%  = (Δuser + Δsys + Δnice) / (Δuser + Δsys + Δidle + Δnice)
```

实测（每核求和 vs `host_statistics`，1 s 窗口，机器有 ~20% 后台负载）：

```
  t=1.0s per-core-sum busy=18.45%  host_statistics busy=18.44%
        per-core-sum: user=170 sys=52 idle=981 nice=0  |  host: user=170 sys=52 idle=982 nice=0
        per-core busy% = [44 47 40 27 20 17 16 6 2 1 1 1]
  t=2.0s per-core-sum busy=19.43%  host_statistics busy=19.43%
  t=3.0s per-core-sum busy=17.83%  host_statistics busy=17.90%
  t=4.0s per-core-sum busy=17.50%  host_statistics busy=17.43%
```

坑：
- 第一次采样没有前值 → 必须显示 **不可用**（不能拿单次绝对值当百分比）。
- `nice` 计入 busy（它在 idle 之外）。
- 差分必须用**无符号回绕减法** `&-`，因为内核计数器是 `natural_t` 回绕的。
- 采样间隔若不是整 1 s，占用率仍然是比值、不受影响；但**换算 CPU 秒**要除以真实间隔。

### 1.4 平滑

同一台机器、10 个 1 Hz 样本、期间有后台负载：

```
  sample  1  raw= 38.10%  ema(0.3)= 38.10%  ma3= 38.10%
  sample  2  raw= 23.88%  ema(0.3)= 33.83%  ma3= 30.99%
  sample  3  raw= 17.28%  ema(0.3)= 28.86%  ma3= 26.42%
  sample  4  raw= 17.45%  ema(0.3)= 25.44%  ma3= 19.53%
  sample  5  raw= 18.57%  ema(0.3)= 23.38%  ma3= 17.76%
  sample  6  raw= 17.64%  ema(0.3)= 21.66%  ma3= 17.89%
  sample  7  raw= 19.63%  ema(0.3)= 21.05%  ma3= 18.61%
  sample  8  raw= 18.17%  ema(0.3)= 20.19%  ma3= 18.48%
  sample  9  raw= 16.93%  ema(0.3)= 19.21%  ma3= 18.24%
  sample 10  raw= 18.23%  ema(0.3)= 18.91%  ma3= 17.77%
  raw: mean=20.59 stdev=6.14
```

- 原始 1 Hz 曲线抖得厉害（stdev 6.14 个百分点，第一个样本 38% 直接把曲线打穿）。
- **EMA(α=0.3)** 约 3 个样本收敛，适合菜单栏读数（但滞后明显：真实值已回落到 18%，EMA 还在 20%）。
- **3 点滑动平均**兼顾跟手与平滑，数值几乎立刻贴住真值（17.8% vs 真值 18.2%）。
- **建议**：菜单栏读数用 **ma3**；浮窗曲线用原始值（画的是瞬时形状）或 ma3；**告警阈值判定必须用原始值或 ma3，不能用 EMA**（EMA 的滞后会让“持续 30 s 超 90%”提前/推迟触发）。

### 1.5 核型（超频 / 性能 / 能效）——本票最难的一块

#### 公开 API 只给数量，不给下标

```
  hw.nperflevels   = 3
  hw.perflevel0   = Super (physical=2 logical=2)
  hw.perflevel1   = Performance (physical=4 logical=4)
  hw.perflevel2   = Efficiency (physical=6 logical=6)
```

`sys/sysctl.h` 里明确写了 `hw.perflevelN.l2perflevels` 是“同一 perflevel 的 CPU 下标位图”，**但本机不存在这个 oid**：

```
  hw.perflevel0.l2perflevels     = sysctl: unknown oid 'hw.perflevel0.l2perflevels'
  hw.perflevel0.l3perflevels     = sysctl: unknown oid 'hw.perflevel0.l3perflevels'
  hw.perflevel0.logicalcpumax    = sysctl: unknown oid 'hw.perflevel0.logicalcpumax'
```

存在的只有 `sharesl2`（哪个 perflevel 与我共享 L2）：

```
  hw.perflevel0.sharesl2 = 2      # 二进制 10 → 与 perflevel1 共享 L2
  hw.perflevel1.sharesl2 = 1      # 二进制 01 → 与 perflevel0 共享 L2
  hw.perflevel2.sharesl2 = (不存在) # Efficiency 不与任何人共享 L2
```

其它两条“想控制线程跑在哪个核”的路都是死的：

```
  host_processor_sets kr=4 count=0        # KERN_INVALID_ARGUMENT，没有“每簇一个 processor set”
  affinity_tag=0 kr=46 -> hottest core=6  # KERN_NOT_SUPPORTED，THREAD_AFFINITY_POLICY 不支持
```

（`thread_policy.h` 原文也说明 affinity tag 只是“给调度器的提示”，本来就不是硬绑核。）

#### 真正能用的源：IODeviceTree 里的每核 `cluster-type`

设备树 `cpus` 节点及其 12 个 `cpuN@N` 子节点带 `cluster-type`：

```
    +-o cpus  <class IOPlatformDevice, id 0x1000002ea, ...>
    | |   "max_cpus" = <0c000000>          # 12
    | |   "cpu-cluster-count" = <02000000> # 2
    | |   "p-core-count" = <06000000>      # 6
    | |   "e-core-count" = <06000000>      # 6
    | +-o cpu0@0   { "cluster-type" = <"E">, "logical-cpu-id" = 0, "cluster-id" = 0, "l2-cache-size" = 0x8000 }
    | +-o cpu1@1   { "cluster-type" = <"E">, "logical-cpu-id" = 1, ... }
    | +-o cpu2@2   { "cluster-type" = <"E">, "logical-cpu-id" = 2, ... }
    | +-o cpu3@3   { "cluster-type" = <"E">, "logical-cpu-id" = 3, ... }
    | +-o cpu4@4   { "cluster-type" = <"E">, "logical-cpu-id" = 4, ... }
    | +-o cpu5@5   { "cluster-type" = <"E">, "logical-cpu-id" = 5, ... }
    | +-o cpu6@100 { "cluster-type" = <"P">, "logical-cpu-id" = 6, "cluster-id" = 0x01000000, "l2-cache-size" = 0x4001 }
    | +-o cpu7@101 { "cluster-type" = <"P">, "logical-cpu-id" = 7, ... }
    | +-o cpu8@102 { "cluster-type" = <"M">, "logical-cpu-id" = 8, "cluster-id" = 0x01000000, "l2-cache-size" = 0x4001 }
    | +-o cpu9@103 { "cluster-type" = <"M">, "logical-cpu-id" = 9, ... }
    | +-o cpu10@104{ "cluster-type" = <"M">, "logical-cpu-id" = 10, ... }
    | +-o cpu11@105{ "cluster-type" = <"M">, "logical-cpu-id" = 11, ... }
```

**这与 `host_processor_info` 的下标是同一个 `logical-cpu-id`**，所以下标 → 核型的映射是：

| 逻辑核下标 | 设备树 `cluster-type` | 数量 | 匹配到的 perflevel | 本项目叫法 |
|---|---|---|---|---|
| 0–5 | `E` | 6 | Efficiency (6) | **能效核** |
| 6–7 | `P` | 2 | Super (2) | **超频核** |
| 8–11 | `M` | 4 | Performance (4) | **性能核** |

**推导依据（唯一解，不是猜的）**：
1. `E` 的数量 6 只能与 Efficiency(6) 对应（`E`=Efficiency 语义也吻合）。
2. 剩下 `P`(2) 与 `M`(4) 与 Super(2)、Performance(4) —— **按数量匹配只有一种双射**：`P`(2)↔Super(2)，`M`(4)↔Performance(4)。
3. **旁证**：设备树里 `P` 与 `M` 的 6 个核 `l2-cache-id` 全为 0、`l2-cache-size` 全为 0x4001（同一个 L2 域），而 6 个 `E` 核的 `l2-cache-size` 是 0x8000（另一个域）；这正好对应 `sharesl2` —— Super 与 Performance 共享 L2、Efficiency 独占。

**代码（`scratch/VitalsMetrics.swift` 有完整可编译版，实测输出见文末）**

```swift
import Foundation      // ← 必须：没有它就没有 String → CFString 的桥接
import IOKit

enum CoreKind: String {
    case superCore = "超频核"     // hw.perflevel0 "Super"
    case perfCore  = "性能核"     // hw.perflevel1 "Performance"
    case effCore   = "能效核"     // hw.perflevel2 "Efficiency"
}

static func readCoreTopology() -> CoreTopology? {
    // 1) sysctl 拿命名与数量
    var namedLevels: [(name: String, count: Int)] = []
    guard let nLevels = vitalsSysctlInt("hw.nperflevels"), nLevels > 0 else { return nil }
    for l in 0..<nLevels {
        guard let c = vitalsSysctlInt("hw.perflevel\(l).logicalcpu"),
              let n = vitalsSysctlString("hw.perflevel\(l).name") else { return nil }
        namedLevels.append((n, c))
    }

    // 2) 设备树拿每核 cluster-type
    //    ⚠️ 设备树节点不在 kIOServicePlane 里！用 IOServiceMatching("IOPlatformDevice")
    //    配合 IOServiceGetMatchingServices【找不到 cpuN@N】，必须显式遍历 IODeviceTree plane。
    let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
    guard cpus != 0 else { return nil }
    var byType: [String: [Int]] = [:]
    var iter: io_iterator_t = 0
    let kr = "IODeviceTree".withCString { plane in
        IORegistryEntryCreateIterator(cpus, plane, UInt32(kIORegistryIterateRecursively), &iter)
    }
    guard kr == KERN_SUCCESS else { return nil }
    while true {
        let e = IOIteratorNext(iter)          // IORegistryIterator 是 IOIterator 的子类
        if e == 0 { break }
        defer { IOObjectRelease(e) }
        guard let type = ioregString(e, "cluster-type"),
              let id = ioregInt(e, "logical-cpu-id") else { continue }
        byType[type, default: []].append(Int(id))
    }
    guard !byType.isEmpty else { return nil }

    // 3) 数量匹配：Efficiency(6)↔"E"(6)；剩下按数量唯一配对 → "P"(2)↔Super(2)、"M"(4)↔Performance(4)
    ...
}
```

**三个实现坑**：

1. `IOServiceMatching("IOPlatformDevice")` + `IOServiceGetMatchingServices` **找不到 `cpuN@N`** —— 这些节点只在 IODeviceTree plane 里。要用 `IORegistryEntryCreateIterator(entry, "IODeviceTree", kIORegistryIterateRecursively, &iter)` + `IOIteratorNext`。
2. `cluster-type` 读回来是 **CFData（2 字节 `"E\0"`）而不是 CFString**，要自己按字节解码。
3. `IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:")` 返回 0，**要写 `"IODeviceTree:/cpus"`**（带子路径）。

实测遍历结果（12 个条目，顺序即逻辑核下标）：

```
  entry  1..6: cluster-type={length = 2, bytes = 0x4500}   // "E"
  entry  7..8: cluster-type={length = 2, bytes = 0x5000}   // "P"
  entry 9..12: cluster-type={length = 2, bytes = 0x4d00}   // "M"
  total entries walked: 12
```

`scratch/probe_cputree.swift` 的完整输出（同一套结论的独立复现）：

```
  hw.nperflevels = 3
  hw.perflevel0 = Super logicalcpu=2
  hw.perflevel1 = Performance logicalcpu=4
  hw.perflevel2 = Efficiency logicalcpu=6
  hw.perflevel0.l2perflevels = <不存在>
  hw.perflevel1.l2perflevels = <不存在>
  hw.perflevel2.l2perflevels = <不存在>
  --- 设备树 cpus 节点 ---
  IODeviceTree:/cpus ok
  max_cpus = 12
  cpu-cluster-count = 2
  p-core-count = 6
  e-core-count = 6
  --- 逐核 cluster-type（遍历顺序即逻辑核下标） ---
  logical-cpu-id=0..5   cluster-type=E
  logical-cpu-id=6,7    cluster-type=P
  logical-cpu-id=8..11  cluster-type=M

  按 cluster-type 归组：
    E: [0, 1, 2, 3, 4, 5]  (6 个)
    M: [8, 9, 10, 11]  (4 个)
    P: [6, 7]  (2 个)
  数量匹配：Efficiency(6)↔"E"(6)；剩下按数量唯一配对 → "P"(2)↔Super(2)、"M"(4)↔Performance(4)
```

#### 想用“跑得慢/快”来反推核型？实测不可靠

后台负载下各核占用（后台减去后测的吞吐，`scratch/out_coretype2.txt`、`out_coretype3.txt`）：

```
  core  0 (E): bg 38.9 ticks/s   core  6 (P): bg 54.4   core  8 (M): bg  3.0
  core  1 (E): bg 38.6           core  7 (P): bg 54.3   core  9 (M): bg  2.0
  core  2 (E): bg 27.6           core  8..11 (M): bg 1.5–3.0
```

- `P` 簇（6/7）长期 ~54%，`M` 簇（8–11）只有 1–3%：**调度器确实优先用快的核**，这与「P=Super」一致。
- 但纯标量吞吐**分不开 P 与 M**：`P` 簇最好 1.122e9 mul/s vs `M` 簇最好 1.099e9 mul/s，只差 2%；SIMD 测下来 11.32e12 vs 11.11e12，同样只有 1–3%。
- 而且测量本身不稳：260 次 220 ms 窗口里能成功归属的只有少数几次；`E` 簇一次都没被采样线程跑到（调度器不放它去）。
- **结论：不要用基准测试反推核型**，用设备树的 `cluster-type` + 数量匹配。

### 1.6 CPU 备选方案与坑

| 备选 | 可用性 | 说明 |
|---|---|---|
| `host_statistics(HOST_CPU_LOAD_INFO)` | ✅ | 只有聚合值，0.89 µs |
| `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | ✅ | 每核，8.23 µs，**推荐** |
| `processor_set_info(PROCESSOR_SET_LOAD_INFO)` | ❌ | 本机 `host_processor_sets` 返回 4，压根没有 set |
| `thread_policy_set(THREAD_AFFINITY_POLICY)` | ❌ | 返回 46；且头文件写明只是 hint |
| `hw.perflevelN.*` | ⚠️ | 只有数量与名称，**没有下标** |
| IODeviceTree `cluster-type` | ✅ | 唯一能给下标的源；非公开 Apple 内部取值，需能力探测 |

---

## 2. 内存

### 2.1 权威来源

`host_statistics64(HOST_VM_INFO64)` → `vm_statistics64`（本机内核返回 104 natural_t = 416 字节，与 SDK 结构体大小一致）。总内存用 `ProcessInfo.processInfo.physicalMemory`（= `hw.memsize` = 17,179,869,184 B = 16 GiB）。

**开销（1000 次）**

```
  host_statistics64(HOST_VM_INFO64) avg=   0.576 us  min=   0.500 us  max=    1.500 us  p50=   0.583 us
  sysctl vm.swapusage              avg=   0.606 us  min=   0.458 us  max=    3.542 us  p50=   0.583 us
  task_info(TASK_VM_INFO) own      avg=   1.023 us  min=   0.791 us  max=    8.375 us  p50=   0.917 us
  ProcessInfo.physicalMemory       avg=   0.489 us  min=   0.375 us  max=    2.083 us  p50=   0.500 us
```

### 2.2 “已用内存”到底是哪个数

一次采样的真实数据（页大小 16384 B）：

```
  total                        = 16.00 GiB
  free                         = 0.36 GiB
  speculative                  = 0.04 GiB
  purgeable                    = 0.02 GiB
  wired                        = 3.44 GiB
  compressor resident          = 3.09 GiB
  internal (anonymous) resident= 3.64 GiB
  active_internal_count        = 2.760 GiB
  inactive_internal_count      = 0.851 GiB
  active_external_count        = 1.403 GiB
  inactive_external_count      = 3.438 GiB
  total_uncompressed_pages_in_compressor = 7.295 GiB
  swap_count                   = 7.261 GiB
```

四种常见口径：

```
  A) (active_internal + inactive_internal - purgeable) + wire + compressed = 10.16 GiB   <-- Activity Monitor「内存使用」
  B) total - free - speculative                                          = 15.60 GiB   <-- 错，把 file-backed 也算进去了
  C) (internal - purgeable) + wire + compressed                           = 10.16 GiB   <-- 与 A 同值
  D) total - free - speculative - purgeable                               = 15.58 GiB
```

**推荐 A 口径**：`已用 = (active_internal + inactive_internal − purgeable) + wire + compressor_page_count`，也就是 **App Memory + Wired + Compressed**，与活动监视器的「内存使用」口径一致。

**菜单栏显示**：按 GLOSSARY 的「内存%」，建议直接用 **A / total = 10.16 / 16.00 = 63%**（菜单栏「内存 63%」= App+Wired+Compressed 占物理内存的比例）。如果菜单栏想表达“还剩多少可用”，那是 **B**（85%）——**两个数不能混用**，界面上要写清楚是「已用」还是「可用」。

### 2.3 macOS 27 的新字段（坑）

`vm_statistics64` 在本机 SDK 里已经扩到 **65 个字段**，其中这几个是新的、语义比旧的更细：

```
  active_internal_count / inactive_internal_count   # 匿名页，按 active/inactive 分
  active_external_count / inactive_external_count   # 文件页
  background_internal_count / background_external_count
  purgeable_pageable_count / purgeable_wired_count
  swap_count                                        # 取代了旧的 swapped_count
  total_uncompressed_pages_in_compressor
```

注意 `swap_count`（新）≠ 旧的 `swapped_count`。用新字段更准（App Memory 直接就是 `active_internal + inactive_internal`）。

### 2.4 内存压力 / 压缩 / swap

```
  sysctl kern.memorystatus_vm_pressure_level = 1     # 1=normal 2=warn 4=critical（位掩码）
  vm.swapusage: total=9216.00 MiB used=7481.12 MiB avail=1734.88 MiB pagesize=16384 encrypted=1
```

- **压力等级**用 `sysctl kern.memorystatus_vm_pressure_level`（≈0.6 µs），不要 fork `memory_pressure`。
- **压缩内存**：`compressor_page_count`（常驻压缩页 × 16 KiB = 3.09 GiB）；`total_uncompressed_pages_in_compressor`（7.30 GiB）是压缩前的逻辑体积，两者别混。
- **swap**：`sysctl vm.swapusage` → `struct xsw_usage`。**坑：`xsu_total/xsu_avail/xsu_used` 的单位是字节**（不是页），别再乘 `xsu_pagesize`（我第一次乘了，得出 147 GB 这种荒谬值）。
- `task_info(TASK_VM_INFO)` 拿到的是**自己进程**的 `phys_footprint`（本机探针自身 1,999,352 B ≈ 1.9 MB），它是「单进程内存」的正确口径（活动监视器每个进程那一列），不是系统总量。

### 2.5 内存备选与坑

| 备选 | 可用性 | 说明 |
|---|---|---|
| `host_statistics64(HOST_VM_INFO64)` | ✅ **推荐** | 0.58 µs，一次拿全 |
| `sysctl vm.swapusage` | ✅ | 0.61 µs；单位是字节 |
| `sysctl kern.memorystatus_vm_pressure_level` | ✅ | 压力等级 |
| `task_info(TASK_VM_INFO)` | ✅ | 只对自己进程有效（`phys_footprint`） |
| `vm_stat` / `top -l 1` fork | ❌ 不必要 | fork 成本 70 ms+ |
| `memory_pressure -Q` fork | ❌ 不必要 | 同样能 sysctl 拿到 |

**坑**：设备树/SDK 与运行内核的结构体大小可能不一致 —— 用 SDK 头文件大小去 `host_statistics64` 会让内核写超界而段错误。本机实测一致（104 naturals = 416 B），但**代码里应该按 4 KiB 对齐的大缓冲读，再自己解释前 N 个字段**（`scratch/probe_mem.swift` 的 `readVM()` 就是这么写的）。

---

## 3. GPU 占用与 GPU 内存

### 3.1 节点：只有一个

```
  IOServiceMatching("IOAccelerator")      -> kr=0 count=1 AGXAcceleratorG18G@d07
  IOServiceMatching("AGXAccelerator")     -> kr=0 count=1 AGXAcceleratorG18G@d0f
  IOServiceMatching("AGXAcceleratorG18G") -> kr=0 count=1 AGXAcceleratorG18G@d17
  IOServiceMatching("IOGPU")               -> kr=0 count=1 AGXAcceleratorG18G@d1f
  IOServiceMatching("IOGraphicsDevice")   -> kr=0 count=0
```

路径：`IOService:/AppleARMPE/arm-io@10F00000/AppleSoCIOPSD/sgx@80000000/AGXAcceleratorG18G`

**用 `IOServiceMatching("IOAccelerator")` 就行**，它会按继承关系匹配到 `AGXAcceleratorG18G`（票面假设正确）。**不要硬编码 `AGXAcceleratorG18G`**（换芯片会变）。

### 3.2 PerformanceStatistics 的内容与稳定性

```
  PerformanceStatistics (single-property read):
     Device Utilization %      = 22
     Renderer Utilization %    = 22
     Tiler Utilization %       = 7
     Alloc system memory       = 10119004160
     In use system memory      = 976273408
     In use system memory (driver) = 0
     Allocated PB Size         = 123731968
     TiledSceneBytes           = 0
     SplitSceneCount           = 0
     recoveryCount             = 0
     lastRecoveryTime          = 0
```

**连续 30 次读（间隔 50 ms）：**

```
  read  0  dev=0  renderer=0  tiler=0
  read  1  dev=22 renderer=22 tiler=7
  read  2  dev=22 renderer=22 tiler=7
  read  3  dev=21 renderer=21 tiler=6
  read  4  dev=0  renderer=0  tiler=0     <-- 又掉 0
  read  5  dev=22 renderer=22 tiler=7
  ...
  read  9  dev=0  renderer=0  tiler=0     <-- 又掉 0
  ...
  Device  : min=0 max=22 distinct=[0, 21, 22]
  Renderer: min=0 max=22 distinct=[0, 21, 22]
  Tiler   : min=0 max=7 distinct=[0, 6, 7]
```

**三个结论**：

1. **Device % 与 Renderer % 恒等**（本机实测每次都一样）。所以**只显示一个就够**，别显示两个一样的数。
2. **Tiler % 是另一个量**（6–7 vs 21–22），是 GPU 的 tile 引擎利用率，跟 3D 渲染不是一回事。
3. **⚠️ 周期性掉 0**：大约每 250 ms 三个值整组归零一次（30 次读里出现 7 次）。这意味着 **1 Hz 采样有大约 1/5 ~ 1/3 的概率读到 0**，哪怕 GPU 正在忙。**必须处理**，否则曲线会不停插针。

**处理办法**：一次采样里连读 3–5 次（间隔 5–10 ms），**取最大值**；或者记住“上一次非 0 值”，只在连续 2 次为 0 时才判 0。取最大值最简单，代价是 3 × 19 µs = 57 µs。

### 3.3 开销

```
  IORegistryEntryCreateCFProperty(PerfStats) avg=  18.954 us  min=  17.625 us  max=  86.583 us  p50=  18.084 us
  IORegistryEntryCreateCFProperty(model)    avg=   2.168 us  min=   1.875 us  max=   6.583 us  p50=   2.083 us
  IOServiceMatching + iterate (no cache)    avg=   3.016 us  min=   2.791 us  max=  19.459 us  p50=   2.917 us
```

- 贵的是**构造整个 CFDictionary**（PerfStats 有 11 个键），不是属性查找本身（`model` 只要 2.2 µs）。
- 重新匹配服务只要 3 µs，**所以缓存不缓存都无所谓**；缓存 `io_service_t` 即可。
- **`IOServiceOpen` 被拒**：`kr = -536870201`（`kIOReturnNotPrivileged`）。所以**不能打开 GPU 设备**，只能读属性。好在属性照样能读、照样会更新。

### 3.4 GPU 内存 / “显存占用”

```
  AGX property 'VRAM'         = nil
  AGX property 'Alloc VRAM'   = nil
  AGX property 'vramSize'     = nil
  AGX property 'VRAMSize'     = nil
  PerfStats 'Alloc system memory'            = 10113613824   (9.42 GiB)
  PerfStats 'In use system memory'           = 812154880     (0.76 GiB)
  PerfStats 'In use system memory (driver)'  = 0
  hw.memsize = 17179869184 bytes (16.0 GiB)
```

Metal 侧：

```
  device: name='Apple M6' headless=false lowPower=false unifiedMemory=true recommendedMaxWorkingSet=12713115648 bytes
    currentAllocatedSize = 65536 bytes
```

**结论（必须写进界面文案）**：

- 这是**统一内存**机器，**没有独立显存**。`MTLDevice.currentAllocatedSize` 只有 64 KiB（只统计 Metal 自己的分配），**不能用**。
- `Alloc system memory` = **9.42 GiB** 是 macOS 给 GPU 划走的那块**系统内存**（carve-out），是静态的，**不是“已用显存”**。
- `In use system memory` = **0.76–0.93 GiB** 才是 **GPU 当前真正占用的系统内存**，这个数会随负载变（实测在 812 MB ↔ 978 MB 之间跳）。
- **所以“显存占用”这个指标不存在，必须改名重定义**。建议中文写成 **「GPU 占用系统内存」**（或「GPU 内存占用（共享内存）」），值取 `In use system memory`。
- 按 GLOSSARY：这是驱动统计口径、不是物理显存，界面上要标为 **近似值**，且**不能**写成“显存”。

### 3.5 GPU 备选与坑

| 备选 | 可用性 | 说明 |
|---|---|---|
| `IOServiceMatching("IOAccelerator")` + `PerformanceStatistics` | ✅ **推荐** | 19 µs；读 `Device Utilization %` |
| 同上 + `In use system memory` | ✅ | 作为“GPU 内存占用” |
| `IOServiceOpen` 打开 GPU 设备 | ❌ | `kIOReturnNotPrivileged` |
| `MTLDevice.currentAllocatedSize` | ❌ 无意义 | 64 KiB，只算 Metal 自己的分配 |
| `IOReport` GPU 通道 | ⚠️ | `IOReportHub` 节点无特权可见，但私有协议未验证（票 01/20 的范围） |

---

## 4. 磁盘吞吐

### 4.1 真正能用的无特权方案：IOKit `IOBlockStorageDriver` → `Statistics`

**实测：无特权可读，且是真实的字节计数器。**

```
  IOServiceGetMatchingServices(IOBlockStorageDriver) kr=0
    IOBlockStorageDriver: Statistics readable, Bytes (Read)=708514869248 Bytes (Write)=517937516544
      keys: Bytes (Read), Bytes (Write), Errors (Read), Errors (Write),
            Latency Time (Read), Latency Time (Write), Operations (Read), Operations (Write),
            Retries (Read), Retries (Write), Total Time (Read), Total Time (Write)
    IOBlockStorageDriver: Statistics readable, Bytes (Read)=985851523584 Bytes (Write)=748484622336
    IOBlockStorageDriver: Statistics readable, Bytes (Read)=807901696   Bytes (Write)=0
    IOBlockStorageDriver: Statistics readable, Bytes (Read)=287051264   Bytes (Write)=0
  total IOBlockStorageDriver nodes: 4
```

- 这些是**自开机以来的累计值**，做 1 s 差分即得速率（和 `host_processor_info` 同一套思路）。
- 4 个节点里：2 个是真实 NVMe 盘（本机 4 块盘：disk0/disk4/disk5/disk6），另外 2 个是**磁盘映像**（`IODiskImageBlockStorageDevice`）。**要挑对节点**，否则会把磁盘映像的 IO 算进去。
- `IOBlockStorageDevice` 层**没有** Statistics 属性（实测 “no statistics property”），必须用 `IOBlockStorageDriver`。
- **开销**：读 4 个节点的 Statistics = **avg 30.26 µs / p50 26.50 µs**。

### 4.2 其他候选

| 方案 | 实测结果 | 结论 |
|---|---|---|
| `statfs("/")` | total=228.23 GiB free=62.71 GiB，**0.522 µs** | 只有容量，**没有 IO 速率** |
| `proc_pid_rusage(RUSAGE_INFO_V2)` | 对**所有** pid 返回 0（含自己、含 launchd） | ❌ 无特权不可用；V0/V1/V4 直接在内核里 abort |
| `FSEvents` / `kqueue` EVFILT_VNODE | 只有变更事件，无字节数 | ❌ 表达不了速率 |
| fork `iostat -d -c 1` | **72.56 ms** | 而且 `-c 1` 给的是**开机以来平均**，不是瞬时 |
| fork `iostat -d -w 1 -c 2` | **1075.82 ms** | 1 s 间隔真实速率，但要等 1 s，**与 1 Hz 采样天然冲突** |

**fork 成本说明**：本机 `fork /usr/bin/true` = **68.57 ms**（avg 20 次）。这远高于普通 macOS 的 2–5 ms，是**本沙箱环境**（seatbelt 拦截）放大的，**不代表真机上也是这个量级**。但结论不变：即使按 3 ms 算，1 秒 fork 一次也是「每秒多一个进程」，不如直接读 IOKit。

### 4.3 推荐做法

```
磁盘读速率 = Σ(所有真实 IOBlockStorageDriver 节点) ΔBytes(Read) / Δt
磁盘写速率 = Σ(所有真实 IOBlockStorageDriver 节点) ΔBytes(Write) / Δt
```

- 采样时把节点的 `Statistics` 都读一遍（30 µs），排除掉 `IODiskImageBlockStorageDevice` 类型的映像盘。
- 计数器是 64 位，**不回绕**，差分用普通减法即可。
- 这不是“近似值”——它就是磁盘控制器报告的实际字节数；但它是**设备级**的，包含文件系统缓存写回，不等于“用户进程的 IO”。界面文案建议写「磁盘读写（系统盘）」。

---

## 5. 网络吞吐

### 5.1 `getifaddrs` + `if_data`：可用，但计数器是 32 位

```
  AF_LINK interfaces: 25
    lo0     flags=0x00008049 up=Y loop=Y ibytes=  2976219136 obytes=  2976219136
    en1     flags=0x00008863 up=Y loop=N ibytes=   865665024 obytes=   314573824
    awdl0   flags=0x00008863 up=Y loop=N ibytes=    15173632 obytes=     5379072
    llw0    flags=0x00008863 up=Y loop=N ibytes=   125870080 obytes=     3667968
    en0/en2/en3/en4/en5/en6/en7/bridge0/ap1/anpi*/gif0/stf0/nan0/utun*  全部 0
```

- **不需要 root**（`getifaddrs` 的 `ifa_data` 在本机可以读到 `if_data`）。
- **⚠️ 坑**：Darwin 的 `struct if_data`（`net/if_var.h`）里 `ifi_ibytes` / `ifi_obytes` 是 **`u_int32_t`** —— **32 位计数器**，4 GiB 回绕。
  - 绝对值不可信（`lo0` 显示 2.98 GB，而 `netstat -ibn` 说 24.45 GB —— 正好是模 2³² 的关系：24,451,215,274 mod 2³² = 2,976,378,794，与 getifaddrs 读到的 2,976,219,136 吻合）。
  - **但差分是对的**（只要 1 s 内不超过 4 GiB），所以做速率没问题。
- **开销**：**avg 24.33 µs / min 21.54 / max 109.92 / p50 21.92**（读全部 25 个接口）。

### 5.2 其它候选

| 方案 | 实测 | 结论 |
|---|---|---|
| `sysctl NET_RT_IFLIST2`（`if_data64`，64 位） | 本机用 `[CTL_NET, PF_ROUTE, 6, 0]` 返回 **0 个接口** | 需要再调 mib 形式；`netstat` 能拿到 64 位值说明内核有这条路，但**这次没调通**，作为待办 |
| fork `netstat -ibn` | **72.84 ms** | 太贵（而且输出要解析） |
| `NWPathMonitor` | `status=satisfied usesWiFi=true ifaces=["en1"] isExpensive=false` | **只有链路状态与接口类型，没有任何字节计数** —— 确认票面判断 |

### 5.3 推荐做法与「排除 loopback 与虚拟接口」

1. 用 `NWPathMonitor` 拿到**当前在用的接口名**（本机是 `en1`），只统计它；没有活动链路时显示 **不可用**。
2. 兜底：遍历 `getifaddrs` 的 AF_LINK 项，排除：
   - `IFF_LOOPBACK`（`lo0`）—— 本机 `lo0` 的收发字节数高达 24 GB，会把真实网络完全淹没；
   - **虚拟接口**：`anpi*`（Apple Network Private Interface）、`awdl0`（AirDrop）、`llw0`（低延迟 WLAN）、`bridge0`/`ap1`（个人热点）、`utun*`（VPN/隧道）、`gif*`/`stf*`/`nan0`。
   - 判据：名字前缀 + `IFF_LOOPBACK` + `IFF_POINTOPOINT`/`IFF_MULTICAST` 组合；实践中「只保留 `en*` 且 `IFF_UP` 且非 loopback」最省事。
3. 差分：`Δbytes` 用无符号回绕减法 `&-`（32 位），再除以真实间隔。

```swift
func networkDelta(previous: (rx: UInt64, tx: UInt64),
                   now: (rx: UInt64, tx: UInt64)) -> (rx: UInt64, tx: UInt64) {
    (rx: now.rx &- previous.rx, tx: now.tx &- previous.tx)   // 32 位计数器回绕
}
```

---

## 6. 进程 Top

### 6.1 两条路对比

```
=== sysctl KERN_PROC_ALL ===
  processes returned: 662
  processes with e_ucred.cr_uid == euid(501): 450
  real-uid histogram (top 8):
    uid=501 count=450
    uid=0   count=141
    uid=235 count=7 ...

=== libproc proc_listpids + proc_pidinfo ===
  pids listed: 662
  PROC_PIDTBSDINFO   ok=450 fail=212
  PROC_PIDTASKALLINFO ok=450 fail=212  total resident=5184 MiB
  cost of list + bsdinfo + taskallinfo for ALL 662 pids: 0.889 ms
  processes with pbi_uid == euid (libproc): 450
```

**关键事实：libproc 的 `proc_pidinfo` 对别的用户的进程直接失败（212 个 root 进程全部取不到）** —— 也就是说**“只看当前用户的进程”这个需求，libproc 是白送的，不需要自己按 euid 过滤**。`proc_bsdinfo.pbi_uid`（有效 uid）也能拿到，双保险。

**开销（1000 次）**

```
  sysctl KERN_PROC_ALL (all procs)   avg=  62.469 us  min=  58.583 us  max= 248.292 us  p50=  60.292 us
  proc_listpids(PROC_ALL_PIDS)       avg=   4.985 us  min=   4.792 us  max=  10.625 us  p50=   4.958 us
  proc_pidinfo(PROC_PIDTASKALLINFO)  avg=   0.511 us  min=   0.417 us  max=   2.458 us  p50=   0.500 us
  proc_pidinfo(PROC_PIDTBSDINFO)     avg=   0.509 us  min=   0.416 us  max=   1.041 us  p50=   0.500 us
  KERN_PROC_ALL + proc_listpids      avg=  66.824 us  min=  63.583 us  max= 138.750 us  p50=  64.792 us
```

**推荐 libproc**：
- 单次 `proc_pidinfo` 只要 0.51 µs，全量 662 个进程扫一遍（list + bsdinfo + taskallinfo）**0.889 ms**，比 `KERN_PROC_ALL`（62.5 µs，但还要自己过滤 uid、再逐个 `proc_pidinfo`）**更省**。
- `KERN_PROC_ALL` 的优势是一次拿到全部（含 uid），适合“想知道全机有几个进程”这种需求；本项目只要自己的进程，libproc 更合适。
- **全量扫描 0.889 ms 相对 1 s 周期只占 0.09%**，1 Hz 扫也扛得住；但为了省电，**建议进程列表 2–3 s 刷一次**，CPU/GPU/内存仍 1 s。

### 6.2 `KERN_PROC_ALL` 的三个坑（踩过了）

1. **缓冲区必须 8 字节对齐**。用 Swift 的 `[UInt8]` 缓冲再 `withMemoryRebound(to: kinfo_proc.self)` 会因为未对齐直接 **SIGTRAP**。必须 `UnsafeMutableRawPointer.allocate(byteCount:alignment:)`。
2. **`p_comm` 不保证 NUL 结尾**（`char[MAXCOMLEN]`，16 字节），满 16 字符的名字会越界读到堆内存 → 段错误。要按字段偏移读原始字节再自己截断。
3. **列表里有 uid = (uid_t)-1 的幽灵进程**。`Int32(cr_uid)` 这种直接转换会在这些条目上 **Swift 运行时 trap**（`Int32(...)` 对越界值会 trap，必须用 `Int32(truncatingIfNeeded:)`）。

### 6.3 每进程 CPU% —— v2 的风险项

- `proc_taskinfo.pti_total_user` / `pti_total_system` 单位是**纳秒**（实测 pid 1834：user 17,565,747,586 ns、sys 9,073,291,399 ns，量级合理）。
- 但**连续两次采样做差**在我的探针里出现了不自洽的巨大差值（~4.6e18），说明**这个结构体在 SDK 与运行内核之间的布局/语义需要再核对**（`sizeof(proc_taskinfo)` Swift 侧是 96，SDK 头文件里 13 个 int32 会补齐到 104）。
- `extern_proc.p_cpticks` / `p_swtime` 在 1 s 窗口内**没有变化**（本机实测），也不能直接用。
- **结论：每进程 CPU% 是 v2 的风险点。** 落地前必须单独验证差分是否稳定；不确定时**降级为只显示 RSS + 进程名**（这两个字段实测稳定：`pti_resident_size` 与 `pbi_comm` 都正常），CPU% 显示 **不可用**。

---

## 7. 电源状态与功耗

### 7.1 「正在用交流电」

```
=== IOPowerSources ===
  IOPSCopyPowerSourcesInfo() -> NON-NIL
  power sources: 0
```

**注意**：票面写「`IOPSCopyPowerSourcesInfo()` 返回 nil」。实测是**返回非 nil 的 blob，但电源列表为空**（0 个 source）—— 因为本机没有电池。两种解读都要能处理：**blob 非 nil 不代表有电池，要看 source 列表是否为空**。

**更好的源（无特权、无 fork）**：

```
=== IOKit power nodes ===
  IOServiceMatching("AppleSmartBattery") -> 1 node(s)
  AppleSmartBattery 的属性（无特权可读）:
    BatteryInstalled   = 0      <-- 没有电池
    ExternalConnected  = 1      <-- 外部电源已接
    IsCharging         = 0
    ChargerCount       = 0
    ExternalChargeCapable = 1
    CurrentCapacity    = 0
    MaxCapacity        = 0
    Voltage            = 0
    Amperage           = 0
    Location           = 0
```

**`BatteryInstalled == 0 && ExternalConnected == 1` 就是「交流电供电」的精确答案**，比解析 `pmset` 文本稳得多。

**开销**：

```
  IORegistryEntryCreateCFProperty(BatteryInstalled)   avg= 2.420 us  p50= 2.292 us
  IORegistryEntryCreateCFProperties(AppleSmartBattery) avg=36.907 us  p50=33.625 us
  IOPSCopyPowerSourcesInfo()                            avg= 8.160 us  p50= 8.083 us
```

**只要单属性（2.4 µs）就够，别拉整张属性表（37 µs）。**

**pmset 兜底**（不推荐，但可用）：

```
  pmset -g ps   -> Now drawing from 'AC Power'
  pmset -g batt -> Now drawing from 'AC Power'
  pmset -g therm-> Note: No thermal warning level has been recorded
                  Note: No performance warning level has been recorded
                  Note: No CPU power status has been recorded
  fork pmset -g ps = 76.02 ms（avg 10 次）
```

### 7.2 功耗（瓦 / mW）

- `ApplePMPv2` 节点**存在且无特权可见**（`IOUserClientClass = ApplePMPv2UserClient`），但读它的数据要打开 user client → **root**。
- `IOReportHub` 节点无特权可见（1 个），但通道数据的私有协议未验证（票 01/20 范围）。
- `powermetrics --samplers cpu_power` 需要 root。
- `AppleSMC` 节点存在，但匹配到的是 `AppleSMCKeysEndpoint`（经典读键端点），按项目既有结论，macOS 27 上这条路已死（`kIOReturnBadArgument`）。
- **结论：无特权拿不到任何瓦数。** 与 map 的既定决策一致：**特权组件唯一用途就是功耗 mW**。

### 7.3 热压力等级

```
  ProcessInfo.thermalState = 0 (nominal)
  isLowPowerModeEnabled = false
```

`ProcessInfo.thermalState` + `ProcessInfo.thermalStateDidChangeNotification` 就能拿四档，零开销、无 fork。`pmset -g therm` 只打印 warning level，且本机是 “No thermal warning level has been recorded”，**没有信息量**。

---

## 8. 落地建议：v1 / v2 / 必须放弃

### v1 可以直接上（全部无特权、全部实测便宜）

1. **CPU 总量 + 每核**：`host_processor_info` 一次调用（8.23 µs）+ 1 s 差分 + ma3 平滑。
2. **按核型分组**：IODeviceTree `cluster-type` + 数量匹配（0–5 能效 / 6–7 超频 / 8–11 性能）。**启动时读一次**即可（核型不会变），失败则退化为 12 根无名柱。
3. **内存**：`host_statistics64(HOST_VM_INFO64)`（0.58 µs）+ `ProcessInfo.physicalMemory`；「已用」用 App+Wired+Compressed 口径；百分比 = 已用/总量。
4. **内存压力等级**：`sysctl kern.memorystatus_vm_pressure_level`（可选展示）。
5. **Swap**：`sysctl vm.swapusage`（0.61 µs，注意单位是字节）。
6. **电源状态**：`AppleSmartBattery` 的 `BatteryInstalled` / `ExternalConnected` / `IsCharging`（2.42 µs）。显示「交流电」/「无电池（台式机）」。
7. **热压力等级**：`ProcessInfo.thermalState`（0 成本）。CPU 数值温度按票 01/04 的结论走降级链。

**v1 单次采样总开销实测 ≈ 11.8 µs（CPU 8.23 + 内存 0.58 + swap 0.61 + 电源 2.42），占 1 s 周期的 0.0012%。**

### v2 再做

1. **GPU 占用**：`AGXAcceleratorG18G` → `PerformanceStatistics`，显示 **Device Utilization %**（与 Renderer % 恒等，不要显示两个），**每次采样连读 3 次取最大**（对抗周期性掉 0）；界面标为 **近似值**。
2. **GPU 内存**：改名 **「GPU 占用系统内存」**，值 = `In use system memory`（0.76–0.93 GiB 波动）；**不要叫显存**。
3. **网络速率**：`getifaddrs` + `if_data` 差分（32 位回绕没问题），只统计 `NWPathMonitor` 指出的活动接口、排除 loopback 与虚拟网卡。
4. **磁盘读写速率**：IOKit `IOBlockStorageDriver` → `Statistics` 差分，排除磁盘映像节点。
5. **进程 Top**：libproc `proc_listpids` + `proc_pidinfo`（天然只返回当前用户的进程）；**每进程 CPU% 先验证差分稳定性**，不稳就只显示 RSS + 名称。
6. **功耗 mW**：交给特权组件（`powermetrics --samplers cpu_power`），无特权时显示 **不可用**。

### 必须放弃 / 改名

| 项 | 处理 |
|---|---|
| **「显存占用」** | **不存在**。改名为「GPU 占用系统内存」，值 = `In use system memory`，并标 **近似值** |
| **每进程磁盘 IO** | **无特权拿不到**（`proc_pid_rusage` 全线失败）→ 放弃这个指标 |
| **`TH_CPU_SCALE = 1000`** | 票面假设**实测为 100/s**。百分比不受影响，但凡是把 tick 换算成 CPU 秒的地方必须按 100/s 标定 |
| **`IOPSCopyPowerSourcesInfo()` 返回 nil** | 实测是**非 nil 但 source 列表为空**，两种都要处理 |
| **「用 affinity 把线程绑到某核」** | 本机不支持（返回 46），且本来只是 hint → 放弃 |
| **`hw.perflevelN.l2perflevels`（下标位图）** | SDK 有文档但本机**没有这个 oid** → 改用设备树 `cluster-type` |
| **fork `iostat` / `netstat` / `pmset` / `memory_pressure` / `top`** | 全部不必要：IOKit/sysctl 都有更快更稳的替代。唯一保留的 fork 场景是功耗（`powermetrics`，且走特权组件） |
| **`mach_absolute_time()` 当纳秒用** | 本机是 24 MHz 时间基，测速会错 41.67 倍 → 改用 `clock_gettime(CLOCK_MONOTONIC_RAW)` |

---

## 9. 开放问题

1. **每进程 CPU% 的可靠算法**（v2 阻塞项）。`pti_total_user/pti_total_system` 纳秒值的连续差分不自洽；需要确定运行内核的 `proc_taskinfo` 实际布局（Swift 侧 `sizeof` = 96，SDK 头文件补齐后 = 104），或改用别的计数器。
2. **`sysctl NET_RT_IFLIST2` 的正确 mib 形式**。本次用 `[CTL_NET, PF_ROUTE, 6, 0]` 返回 0 条；`netstat -ibn` 能拿到 64 位 `if_data64`（`lo0` Ibytes = 24,451,215,274），说明内核有这条路。如果要 64 位计数器（避免 32 位回绕的麻烦），值得再试。
3. **GPU 利用率掉 0 的机制**。目前只知道「约每 250 ms 整组归零」，不知道是驱动更新周期还是「本周期无新提交」。取最大值是权宜之计；如果驱动是按提交批次刷新的，也许读 `AGXGPURawCounter` 原始计数器能拿到更连续的数据（私有路径，风险高）。
4. **磁盘节点筛选规则**。本机 4 个 `IOBlockStorageDriver` 里 2 个是磁盘映像。判据应该用父节点类名（`IODiskImageBlockStorageDevice`）还是 `Statistics` 里的盘符？多盘场景下界面怎么表达（合计 or 分盘）？
5. **设备树 `cluster-type` 的稳定性**。`E`/`P`/`M` 是 Apple 内部取值、无公开文档，且簇构成会随芯片变。**必须做能力探测 + 数量匹配 + 失败降级**，并且在核型数量与 `hw.perflevelN` 对不上时**整体退化为“不分组”**，而不是显示错误的分组。
6. **「Super」这个名字**。本机 `hw.perflevel0.name` = "Super"，GLOSSARY 里叫「超频核」。设备树那边叫 `P`（2 个）。这个字母与 Apple 内部命名的对应关系没有公开文档，我们只是靠数量唯一配对得出 —— 换一台机器（比如 perflevel 数量不是 3，或者 P/M 数量和 Super/Performance 不匹配）时，这条推导就不成立了，需要有兜底。
7. **本沙箱的 fork 成本被放大了**（`/usr/bin/true` 68.6 ms，真机通常 2–5 ms）。所有“fork 方案”的成本结论在真机上要重新量一遍；不过结论方向不会变（IOKit/sysctl 依然远优于 fork）。
8. **`mach_absolute_time()` 的时间基**。本机它**不是纳秒**（10 s 墙钟只前进 0.24 s，即 24 MHz 时间基）。如果代码里拿它当纳秒用，测速会错 41.67 倍。用 `clock_gettime(CLOCK_MONOTONIC_RAW)` 或 `DispatchTime`。
9. **私有 IOKit 路径的边界**。设备树 `cluster-type`、AGX `PerformanceStatistics`、`IOBlockStorageDriver` `Statistics` 三处都不是公开 API。按项目约定（私有 IOKit API 只允许出现在温度模块内），**需要为它们单独立 ADR**，说明「只读、不打开 user client、有能力探测与降级」。

---

## 附录 A：可复用代码与原始输出

| 文件 | 内容 |
|---|---|
| `scratch/VitalsMetrics.swift` | 各指标后端的可抄实现（CPU / 内存 / GPU / 磁盘 / 网络 / 进程 / 电源 / 核型），带 `@main` 自测入口 |
| `scratch/probe_cpu.swift` | CPU 后端探针（差分、平滑、processor_set、affinity） |
| `scratch/probe_tickscale.swift` / `probe_tickscale2.swift` | tick 比例标定（结论：100/s） |
| `scratch/probe_spin.swift` / `probe_coretype2.swift` / `probe_coretype3.swift` | 核型反推实验（结论：基准测试分不开，改用设备树） |
| `scratch/probe_cputree.swift` | 设备树 `cluster-type` 提取 |
| `scratch/probe_mem.swift` | 内存 / swap / 压力 |
| `scratch/probe_gpu.swift` | GPU 占用 + GPU 内存 + Metal |
| `scratch/probe_disk_power.swift` | 磁盘统计 + 电源 |
| `scratch/probe_net.swift` | 网络接口与字节计数 |
| `scratch/probe_proc.swift` | 进程列表（两种后端）+ 成本 |
| `scratch/probe_clock.swift` | 时钟源成本与 CPU 计账归属 |
| `scratch/out_*.txt` | 上述探针的原始输出（报告里的数字都出自这里） |

编译方式（本机只有 Command Line Tools）：

```bash
swiftc -swift-version 5 -O -parse-as-library \
  -module-cache-path "$PWD/.modulecache" -Xcc -fmodules-cache-path="$PWD/.modulecache" \
  -o scratch/bin/VitalsMetrics scratch/VitalsMetrics.swift \
  -framework IOKit -framework Metal -framework Network
```

## 附录 B：`scratch/VitalsMetrics.swift` 自测输出（2026-11-14 21:02）

```
=== 核型 ===
  逻辑核 0 -> 能效核
  逻辑核 1 -> 能效核
  逻辑核 2 -> 能效核
  逻辑核 3 -> 能效核
  逻辑核 4 -> 能效核
  逻辑核 5 -> 能效核
  逻辑核 6 -> 超频核
  逻辑核 7 -> 超频核
  逻辑核 8 -> 性能核
  逻辑核 9 -> 性能核
  逻辑核 10 -> 性能核
  逻辑核 11 -> 性能核
  perflevel 计数: [(name: "Super", count: 2), (name: "Performance", count: 4), (name: "Efficiency", count: 6)]

=== CPU ===
  总量 busy=21.58%  每核=43 47 42 22 19 21 34 26 3 2 1 0

=== 内存 ===
  已用 10.72 GiB / 16.00 GiB (67.0%)  app=4.97 wired=3.02 compressed=2.73
  swap 7158 MiB / 8192 MiB  压力等级=1

=== GPU ===
  device=32% renderer=32% tiler=7%  GPU 占用系统内存=0.72 GiB（划给 GPU=9.43 GiB）

=== 磁盘 ===
  读 0.0 KB/s  写 0.0 KB/s

=== 网络 ===
  en1  收 1556.4 KB/s  发 183.1 KB/s

=== 进程（当前用户） ===
  446 个进程；前 5 个按 RSS：
    pid=23095 DeepSeek Harnes rss=671.7 MiB uid=501
    pid=3430 TencentMeeting rss=436.6 MiB uid=501
    pid=4588 com.apple.WebKi rss=319.1 MiB uid=501
    pid=3189 com.apple.WebKi rss=303.2 MiB uid=501
    pid=46006 steamwebhelper. rss=290.0 MiB uid=501

=== 电源 ===
  状态=交流电  充电中=false  有电源源列表=false
```
