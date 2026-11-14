Type: research
Status: open
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
