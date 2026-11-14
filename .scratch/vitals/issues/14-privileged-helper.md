Type: task
Status: open
Blocked by: 06, 21

# 特权组件（LaunchDaemon + 本地 socket）

## Question

实现自研的特权组件，作为**可选**组件提供**功耗数据**（CPU/GPU/ANE 功率 mW）。

**用途已因票 02 而改变**：温度不再需要特权（macOS 27 的 powermetrics 已无 smc sampler，root 也拿不到 die °C）；特权状态下仍然拿得到的机器健康数据是功耗——`powermetrics --samplers cpu_power --show-extra-power-info -f plist`（plist 为 NUL 分隔，键 `cpu_power`/`gpu_power`/`ane_power`/`combined_power`）。

**先决**：本票是否还成立，取决于票 21 的结论（要不要为功耗装特权组件）。若 21 决定不装，本票作废并从地图上删掉；若决定装，则按下面的要求做。

实现要求：

要交付：

- `VitalsHelper`：以 root 身份由 launchd 启动的 LaunchDaemon，通过 unix domain socket 提供只读查询。
- **安全边界**（按已定决策）：键名白名单（只接受预先批准的键，拒绝任意键名）；校验对端 uid 为登录用户；socket 仅属主可读写（权限 0600）；每次查询写审计日志；不接受任何写操作。
- **但要注意这里的"键名白名单"语义变了**：功耗来自 `powermetrics`，不是 SMC 键，所以白名单的对象不是键名而是**被允许的命令与参数**——请求只能表达"取功耗"这一个动作，helper 内部自己拼 `powermetrics --samplers cpu_power --show-extra-power-info -f plist`，绝不允许客户端传入任意命令行参数或路径（否则 root helper 立刻变成任意命令执行）。若将来要加第二个指标，用固定的动作枚举，不接受自由字符串。
- 协议：请求/响应格式自定（建议 JSON 行），要能区分"取不到"与"读取失败"；实现超时、重连与健康检查。
- 缓存与节流：1s 采样直接 fork powermetrics 太重——helper 内部自己维持一条 `powermetrics` 长驻采样流（或按固定间隔缓存），客户端只是取最近一次快照；采样间隔与缓存时长写进文档。
- 生命周期：开机自启、异常退出后由 launchd 拉起、卸载时干净移除（socket 文件、日志、plist）。
- 降级：helper 没装/没跑/超时 → app 侧功耗显示"不可用 + 原因"，其余指标不受影响。

产出：helper 源码 + LaunchDaemon plist 模板 + 安全说明（在 `docs/` 写明威胁模型、允许的动作枚举，以及"为什么不把整个 app 跑在 root 下、为什么不装第三方二进制"）。
