Type: task
Status: open
Blocked by: none

# 验收清单与量化指标

## Question

定义"做完了"的客观标准——一份可勾选的验收清单，让实现票都以它为准。

要交付（写入 `docs/acceptance.md`）：

- **数据准确性**：CPU 总占用与 `top`/Activity Monitor 的偏差阈值；每核数值合理性；温度与外部基准（如另一个读数途径或 heat soak 观察）的允许偏差与合理区间；内存与 `vm_stat`/`活动监视器` 一致性；GPU 占用与读数来源自洽。
- **实时性**：1s 采样下，界面数值落后于真实值的上限；曲线 60s 窗口的滚动是否平滑无跳变。
- **资源占用**：常驻内存上限、CPU 占用上限（采样本身应可忽略）、唤醒/休眠后是否恢复采样。
- **行为**：开机自启生效、helper 未安装时的降级表现、告警触发与冷却（不重复刷屏）、阈值修改后立即生效、菜单栏迷你读数与浮窗数值一致。
- **安装**：`.pkg` 双击安装后 app 出现在 /Applications、LaunchAgent 已注册、helper 状态符合预期、卸载后无残留。
- 每条写明**验证步骤**（具体命令或操作）与**通过阈值**，不允许"看着差不多"。
- 测试形式：本机没有 XCTest / swift-testing，单元测试用 `Tests/VitalsCoreTests` 的零依赖断言运行器（`scripts/test.sh`）；其余靠手动验收。

产出：`docs/acceptance.md`，并在 README 里链接它。
