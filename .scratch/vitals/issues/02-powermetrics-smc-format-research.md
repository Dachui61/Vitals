Type: research
Status: open
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
