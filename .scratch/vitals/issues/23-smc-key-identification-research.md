Type: research
Status: resolved
Blocked by: none

# 哪个 SMC 键才是 CPU die 温度

## Question

票 01 证明了 `/usr/lib/libSMC.dylib` 能无特权读到数值温度（TH0x / TH0a / TH0b / TMVR / Tp05 / Tp09），但**没确定哪个键是 CPU die**。键语义随芯片/机型而变，Apple 不公开文档，不能靠名字猜、也不能靠"哪个更热"。

必须产出**可复现的证据链**，把"CPU die"这个键定下来——界面上显示的"核心温度"必须真的是 CPU die，而不是 GPU 或 SoC 热点。

方法：

1. **穷举候选**：用 `SMCGetKeyInfo` 列出本机所有可读的温度类键（不止已知那六个）。先确认 libSMC 是否支持按键前缀/类别枚举；若不支持，就用候选清单扫：`Tp0*` / `Tp1*` / `Th*` / `TH*` / `TM*` / `TA*` / `TG*` / `TC*` / `TS*` / `TW*` 等，逐个记录"存在/不存在（rc=-3）/数值/是否随负载变化"。
2. **CPU 负载选择性**：用 `scratch/smc_temp.swift --load`（或自写压测）把 CPU 打满 20–30 秒，记录各键的升温曲线。**只有跟着 CPU 负载涨的键**才是 CPU 侧候选。
3. **GPU 负载反证**：制造纯 GPU 负载（本机只有 Command Line Tools，`metal` 编译器不一定可用——先试 `xcrun metal`；不可用就用 Swift + CoreGraphics/CoreImage 离屏渲染循环，或 Metal compute）持续 20–30 秒，记录各键变化。**跟着 GPU 负载涨、却不跟 CPU 涨**的键是 GPU die，要被排除。
4. **交叉验证**：`/usr/sbin/systemstats`（Apple 自带、链接了 libSMC）在本机能否输出温度？`system_profiler` 的哪些子项带温度（SPPowerDataType / SPHardwareDataType / SPPCIDataType）？若 systemstats 直接报出 CPU die 温度并与某个键吻合，那是最强证据。
5. **可选 root 交叉验证**（低优先级，需要用户在普通 Terminal 跑；做法见已作废的票 22）：root 下读同一批键，值应与无特权一致——只证明权限不是变量，不证明键语义。

产出要求：

- 一张表：键名 | 空闲值 | CPU 负载响应 | GPU 负载响应 | 判定（CPU die / GPU die / SoC 热点 / 未知 / 不存在）。
- 明确给出**主显示键**（一个）与**降级顺序**（主键读不到时依次用哪个）。
- 记录每个键的**可信度**：如果只能靠负载相关性推断、无法直接确认，就明确写"推断"——界面按 GLOSSARY 把它标为"近似值"。
- 结论要能直接喂给票 04（后端选型与降级契约）与票 09（实现）。

产出文件：`research/smc-key-identification.md`（含命令、源码、原始曲线数据）。

## Answer

**结论：主用键 `Tp0j`；降级链 `Tp0j → Tp0g → Tp09 → Tp07 → Tp0b → Tp05 → Tp0m → Tp0L`。** 置信度中高，但属"负载相关性推断"而非 Apple 官方确认 → 按 GLOSSARY，界面必须标**近似值**并显示传感器名（本机 `SMC Tp0j`）。

**必须排除**：`Tg*`（18 个）是 **GPU 侧**；`TVD0/TVDC/TVDP/TCMb` 是 **SoC 封装/热点级**（整机最热，单核满载 73 °C，CPU+GPU 都推高它——选它等于"把 SoC 热点当 CPU"）；`TPD*` 混合；`TH0x/TH0a/TH0b/TMVR/TR*d/TW0P/TT0P/TN00/THSP/TPSP/TVN*` 不随负载动（≤1.7 °C，环境/板级）。

**重要修正**：票 01 把 `TH0x` 列为候选是**错的**——本机 CPU 满载下它完全不动。很多第三方工具在 Apple Silicon 上默认用它。

**证据表（中位数 °C）**：

| key | 空闲 | CPU 12核 | GPU 满载 | P核单线程 | E核单线程 | 判定 |
|---|---|---|---|---|---|---|
| **Tp0j** | 44.1 | 56.8 (+12.8) | 53.6 (+6.0) | **65.0 (+19.3)** | 42.4 (±0) | **CPU die（主用）** |
| Tp0g | 43.6 | 54.5 (+10.9) | 52.9 (+5.9) | 63.7 (+18.6) | 41.9 (−0.4) | CPU 第2 |
| Tp09 | 43.7 | 54.9 (+11.2) | 52.5 (+5.8) | 58.0 (+12.3) | 42.5 (−0.1) | CPU 第3 |
| Tp07 | 42.8 | 53.2 (+10.4) | 51.6 (+6.0) | 56.8 (+12.3) | 41.5 (−0.4) | CPU 第4 |
| Tp0b/Tp05/Tp0m | 42–43 | 52–55 | 50–51 (+6.2~6.5) | 48.8–50.9 | 平 | CPU 第5–7 |
| Tp0L | 41.3 | 54.3 (+13.0) | 52.7 (+9.5) | 46.5 (+3.1) | 40.3 | CPU 侧偏聚合 |
| Tg*(18) | 41–42 | 46–47 (+5.1~5.7) | **55.9–59.2 (+13.4~16.3)** | +1.3~2.3 | 平 | **GPU die，排除** |
| TVD0/TVDC/TVDP/TCMb | **52–55** | 64.9 (+12.2) | 65.1–65.6 | **73.0 (+18.3)** | 51.9 | **SoC 热点，排除** |
| TPD0/TPDX | 44.7/44.9 | 59.3 (+14.5) | 57.9/65.5 | 57.1 | 平 | 混合（die 级） |
| Ts*(9)/Te0*(7)/Ta0*+Te0f+Te0g+Ts05 | 40–43 | +3.6~7.6 | +6.6~13.5 | 平 | 平 | 混合 / 同一传感器的 15 个别名 |
| TH0x/TH0a/TH0b/TMVR/TR*(14)/TW0P/TT0P/TVN*/TN00 | 35–43 | ≤1.1 | ≤3 | ±0.2 | 平 | 环境/板级，非 die |
| TC0P/TC0F/TCHP/TCXC/TM0P/TG0D | — | — | — | — | — | 不存在 |

**可复现方法**：libSMC 有**全量枚举 API** `_SMCGetKeyFromIndex(conn, index, &outKey)`（由 `dyld_info -disassemble /usr/lib/libSMC.dylib` 反汇编得出），遍历得 **2066 个键**，温度键是连续一段 index 556–703（148 个，其中 130 个读数落在 (5,120) °C）→ 温度键集合枚举完整。GPU 负载用 **MPS 高斯模糊**（`MPSImageGaussianBlur` 4096², sigma 24；`xcrun metal` 不可用），GPU 利用率用 `ioreg -r -c AGXAccelerator -l` 独立确认 90–95 %。核簇定位：`THREAD_AFFINITY_POLICY` 本机不支持（`thread_policy_set` 返回 46，与票 03 一致），改用 `DispatchQueue(qos: .userInteractive)` 单线程压性能核 / `.background` 压能效核——前者把 `Tp0j` 顶到 65 °C，后者一动不动。

**给实现的三条硬规则**：

1. **不要按"谁的温度高"挑键**——`TVD0` 一族最高，但 GPU 也会推高它。
2. **不要用 `TH0x`**——Apple Silicon 上很多工具默认用它，本机它是环境温度。
3. **键语义与芯片/机型相关**，`Tp0j` 只对本机成立 → app 应运行时探测：枚举 `T*` 候选 → 起 1–2 s 单线程 userInteractive CPU 负载 → 取涨幅最大的键。本机该流程唯一选出 `Tp0j`（+19.3 °C，全候选最高）。**探测策略由票 04 定**（见其正文）。

**交叉验证不可得**：`powermetrics --samplers thermal` 即使有 root 也只打印 thermal pressure、不打印温度数值（macOS 27 已无 die 温度通道）；Apple 未向用户态公开任何 die 温度↔SMC 键对照表（`systemstats` 内置的是 Intel 键表；`AppleSMCKeysEndpoint` 需特权）。所以"近似值"这个标注是**长期事实**，不是权宜之计。

产物：`research/smc-key-identification.md`；可复用代码 `scratch/smc_keys.swift`（`SMCClient` + 全量枚举 + `--temps` 采样 + CPU/GPU 负载发生器 + `enumerate|watch|info` 三模式）；原始数据 `scratch/smc_all_keys.tsv`(2066 键) / `cpu_load.tsv` / `gpu_load.tsv` / `load_p1.tsv` / `load_e1.tsv`。
