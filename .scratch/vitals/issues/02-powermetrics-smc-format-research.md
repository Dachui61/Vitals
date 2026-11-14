Type: research
Status: resolved
Blocked by: none

# powermetrics SMC sampler 的输出格式与 CPU 温度提取

## Question

以 root 运行 `powermetrics --samplers smc -i 1000` 时，输出里 CPU 温度的**具体字段格式**是什么？作为特权 helper 的数据源是否够稳、够轻？

需要查清：

- 实测输出：`sudo powermetrics --samplers smc -i 1000 > /tmp/pm.txt`（若沙箱不允许 root，就给出需要用户在普通 Terminal 执行的两条命令与采集步骤，让用户回传文件后继续分析）。
- CPU die 温度是否真的出现在 smc sampler 里（而不是只有风扇转速/频率）？字段名、单位（°C 还是 0.1°C 定点？）、以及是否有多路温度（CPU die / GPU / 内存 / 供电）。
- 长期后台用的可行性：是否持续稳定输出、CPU 与内存开销、退出行为、能否只取 SMC 而不取其他 sampler。
- 有没有更轻的替代（例如直接读 `/dev` 或某个特权可访问的 SMC 变体），若没有就明确说没有。
- 解析器设计建议：如何稳定锚定"CPU 温度"那一行（而不是靠脆弱的行号），建议的正则/键名映射，以及缓存与平滑策略。

产出：`research/powermetrics-smc-format.md`——真实输出样本、字段说明、解析器建议；本票以该文件与一句话结论作为答案。

## Answer

**结论：死路。macOS 27 上 `powermetrics --samplers smc` 根本不存在，root 也救不了**——"特权 helper 代跑 powermetrics 拿 CPU °C"这条路作废，不要为温度建特权组件。

- `powermetrics --samplers smc` 在**参数解析阶段**就被拒：`powermetrics: unrecognized sampler: smc`，exit 64；root 与非 root 完全一致。
- 本机实际运行的 arm64e 切片里，"smc"/"SMC"/"temperatur" 字节出现次数为 **0**：SMC sampler 与全部 die 温度打印在 Apple Silicon 构建里被删掉了。
- macOS 27 的 sampler 名单（`--help` 为权威）：tasks, battery, network, disk, interrupts, cpu_power, thermal, sfi, gpu_power, ane_power。注意 `thermal_pressure` **不是** sampler 名（正确的是 `thermal`），也不存在 `smc`。`man powermetrics` 里那节 SMC 文档是 2012 年的陈旧页面，不可当规格。
- arm64e 的 `thermal` sampler 只给压力等级（"Current pressure level: Nominal"，plist key `thermal_pressure`），永远没有 °C；`--show-extra-power-info` 给的是 **mW**（CPU/GPU/ANE Power），不是温度。
- powermetrics 曾经打印过的温度格式**只存于 Intel x86_64 切片**（本机用不到）：文本 `CPU die temperature: %.2f C`，plist key `cpu_die`。修正本票的猜测：它**从不打印原始 SMC 键名**（TC0P/TA0P/TG0P 在二进制里 0 命中），所以"解析 TC0P=xx"式的设计本就不成立。
- 真正免费可用的替代：`ProcessInfo.thermalState` + `thermalStateDidChangeNotification`（本机 uid=501 已验证）。
- **特权状态下仍然拿得到的是功耗**：`powermetrics --samplers cpu_power --show-extra-power-info -f plist`（plist 为 NUL 分隔）→ CPU/GPU/ANE/combined 功率 mW。这是特权组件新的、也是目前唯一站得住的用途。
- 运维细节（将来若做功耗 helper）：显式 `-n -1`；SIGINT/SIGTERM/SIGHUP 退出，SIGINFO 立即采样，SIGIO flush；exit 64 = 参数错（别重试），exit 1 = 非 root（永久失败）；1Hz 绝不使用 `--samplers all`/`default`。
- UX 文案：非 root 时 stderr 为 "powermetrics must be invoked as the superuser"（exit 1）。

完整报告：[research/powermetrics-smc-format.md](../../research/powermetrics-smc-format.md)（分支 `research/powermetrics-smc-format`）
