Type: research
Status: resolved
Blocked by: none

# IOReportHub 能否无特权读到 CPU 数值温度

## Question

在 macOS 27 / Apple M6 上，**无特权**进程能否通过 IOReportHub 的私有协议读到 CPU die 的数值温度？

需要查清并用可运行的代码证明：

- IOReportHub（IOKit user client，`IOServiceMatching("IOReportHub")`）在 uid=501 下能打开，已知 types 0..31、methods 0..5 可用——据此实现私有协议客户端：IOReportDescriptor / IOReportChannel 结构布局、magic `0x4D524550`("MREP")、class 过滤（`0x3A27E83B` 为温度类）、以及按字符串（如 "CPU Die Temp"、"TCC"、"Die Temp"）定位通道。
- `IOPerformance.framework` 已从 macOS 27 的 dyld 缓存移除，**不要依赖它**；必须自行实现协议。
- 结论要明确：能读到 / 读不到 / 需要额外权限。若能：温度数值是否落在 30–60°C 合理区间、采样频率与单次开销；若不能：阻断点是什么（权限拒绝、通道消失、协议变更）。
- 风险面：这是私有 API，系统升级后失效的判断依据是什么，将来如何做能力探测与自动降级。

产出：`research/io-report-temperature.md`——含完整可运行 Swift 源码、实际命令与原始输出片段；本票以该文件与一句话结论作为答案。

## Answer

**结论：IOReportHub 给不出温度（通道不存在，且读值被 KERN_NO_SPACE 挡住）；但 macOS 27 的新 `/usr/lib/libSMC.dylib` 能无特权读到数值温度。** 温度路线因此从"只能靠特权"变成"无特权可做"。

**IOReportHub 确实不行**（三条独立理由）：

- `IOPerformance.framework` 已从 dyld 缓存移除；实现搬到了 `/usr/lib/libIOReport.dylib`（可 dlopen，导出 `IOReportCopyAllChannels` / `IOReportCreateSubscription` 等新 C API，旧名 `IOReportCopyChannelValues` 已死）。
- macOS 27 的 IOReport 通道空间里**没有任何 CPU die 温度通道**：无特权枚举出约 8450 个通道，0 个匹配 "die"。名字像温度的只有 `Temperature(0)`（RTBuddy 内部遥测）、`SOCHOT0_L/1_L`（hot 计数器）、12 个 `*_TVM_PERFCNT_TEMP_REGION*` 性能计数器——都不是 °C 的 CPU die。
- 经典 'MREP' descriptor 握手已消失：magic 0x4D524550 + class 0x3A27E83B 的结构方法调用在 methods 0–5 全部 `kIOReturnBadArgument`（-536870206）。
- `IOReportCreateSubscription` 本身**成功**（hub 接受兴趣列表），但下一步 `IOReportCreateNewRawSamplesBuffer()` 返回 nil，err = NSMachErrorDomain 268435459（0x10000003，KERN_NO_SPACE），reason "_updateKernelBuffer() failed"；用全量 8450 通道或只用 1 个通道都一样。**连 Apple 自己的 macOS 27 reader 在本机也拉不到 IOReport 的值。**
- 原始协议细节：user-client type 是 **515**（types 0..255 全部打不开，只有 515 能开）；新协议 = open(515) → method 0 协商 → method 2 配置兴趣列表（`{u32 count; pad; items[24]{u64 driverID, u64 channelID, u64 format}}`）→ IOConnectMapMemory → method 3 更新内核缓冲区。

**转折点 —— `/usr/lib/libSMC.dylib`（经典 SMC 的继任者）**：

- dlopen `/usr/lib/libSMC.dylib` 后可用 `SMCOpenConnectionWithDefaultService` / `SMCReadKeyAsNumeric` / `SMCGetKeyInfo`。
- **无特权（uid=501）实测有数值温度**（本人已独立复现）：空闲 TH0x≈50.2 / TH0a≈50.2 / TH0b≈49.5 / TMVR≈50.9 / **Tp05≈54–59** / **Tp09≈56–66** °C；4×`yes` 压测 10 秒后 Tp05 **+10.9 °C**、Tp09 **+6.3 °C**、TH0x 基本不动——传感器是活的，不是常量。
- 经典键 TC0P / TC0F / TCHP / TCXC / TM0P / TG0D 在本机**不存在**（`SMCGetKeyInfo` rc=-3）。
- 单次读约 **97–123 µs**（200 次平均），1 Hz 采样绰绰有余。
- 值的 out 参数实测是 **IEEE-754 double，单位 °C**。**注意 key 打包是大端**（`'T'<<24|'C'<<16|'0'<<8|'P'`），与票 20 里 IOKit 端点的低字节序打包**不一致**——两套路径不要混用。

**仍未确定（转交新票 23）**：哪个键才是 CPU die。Tp05 对 CPU 负载最敏感，Tp09 更热且与 CPU 负载耦合更弱——也可能是 GPU die 或 SoC 热点。键语义随芯片/机型而变且无文档，不能靠名字或"谁更热"来猜。

可复用实现：`scratch/smc_temp.swift`（已实测可编译可运行；`--load` 压测模式、`--seconds N`）。

完整报告：[research/io-report-temperature.md](../../research/io-report-temperature.md)（分支 `research/io-report-temperature`）
