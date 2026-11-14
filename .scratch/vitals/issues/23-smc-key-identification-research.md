Type: research
Status: open
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
