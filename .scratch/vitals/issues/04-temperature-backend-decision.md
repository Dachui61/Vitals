Type: grilling
Status: open
Blocked by: 23

# 温度后端选型与降级契约

## Question

依据 01（IOReportHub 不可行，但发现 `/usr/lib/libSMC.dylib` 可无特权读数值温度）与 23（哪个键是 CPU die）的结论，**数值 CPU 温度**最终走哪条后端？

**已被排除**：
- IOReportHub——macOS 27 的通道空间里没有 CPU die 温度通道，且原始样本缓冲区被 KERN_NO_SPACE 挡住（票 01）。
- 特权 powermetrics——macOS 27 已无 smc sampler，root 也拿不到 die 温度（票 02）。

**候选**：
- (a) **`/usr/lib/libSMC.dylib`（无特权）**——`SMCOpenConnectionWithDefaultService` / `SMCReadKeyAsNumeric` / `SMCGetKeyInfo`，单次读 ~100 µs，1 Hz 无压力。需票 23 定下"CPU die 是哪个键"。私有 API，须带能力探测（dlopen 失败 / 符号缺失 / 键不存在 → 一律走降级）。
- (b) **thermalState 四档**——公开 API，零成本，唯一的保底。
- (c) **组合**：(a) 优先，失败降 (b)，再失败显示"不可用 + 原因"。

若 (a) 的键语义最终只能靠负载相关性**推断**（而非直接确认），则界面必须按 GLOSSARY 把读数标为**近似值**——这条要写进 SPEC 的可信度标注规则。

同时要在本票定下**降级契约**（写进 SPEC，不能含糊）：

- 后端不可用时界面显示什么：温度栏显示"温度不可用（原因）"占位，还是直接隐藏温度栏？
- 降级到 thermalState 四档时，告警如何表现（只保留 CPU 阈值？温度告警自动禁用？）
- "传感器名"的展示规则：主传感器如何选（多个候选键时按什么优先级）、无特权读到时如何标注"近似值"、特权读到时如何标注来源。
- 温度数据的可信度标注：什么情况下必须显示"近似"徽标。

产出：本票的结论 = 一段决策陈述（含选型、优先级、失败降级路径、可信度标注规则），并作为 ADR「温度后端与降级策略」的素材。
