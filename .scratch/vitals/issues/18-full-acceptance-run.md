Type: task
Status: open
Blocked by: 17

# 全量验收执行与缺陷修复

## Question

按 `docs/acceptance.md` 逐条执行验收，勾掉通过项，修掉不通过的项。

要交付：

- 在本机真实环境跑完每一条验收项，记录命令、观测值、结论（通过/不通过/跳过+原因）。
- 不通过的项要么修掉，要么在 SPEC 里显式记录为已知限制（不许默默跳过）。
- 特别复核：数值可信度（温度与 CPU 与系统工具对照）、1s 采样的资源占用、开机自启、helper 未安装时的降级、告警不刷屏、卸载无残留。
- 输出一份验收报告 `docs/acceptance-report.md`（含实测数字与截图），作为这个 map 的收尾证据。

产出：`docs/acceptance-report.md` + 相应代码修复。
