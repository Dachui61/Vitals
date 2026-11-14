Type: task
Status: open
Blocked by: 06, 21

# 特权组件（LaunchDaemon + 本地 socket）

## Question

实现自研的特权组件，作为**可选**组件提供 **CPU/GPU/ANE 功耗（mW）**。

**用途已大幅缩小（读票 01 后）**：温度现在**不需要特权**——`/usr/lib/libSMC.dylib` 无特权即可读到数值温度（票 01），所以这个组件剩下的唯一用途是功耗。是否还值得装，取决于票 21。

**已排除的用法**：
- 不要用它读温度：票 02 证明 powermetrics 无 smc sampler；票 01 证明 libSMC 无特权就够。
- 不要用它实现票 20 还原的 168 字节 IOKit SMC 协议：那条路虽然协议完整，但 root 是否放行从未验证，且已经不需要了。

若票 21 决定保留本票，实现要求：

要交付：

- `VitalsHelper`：以 root 身份由 launchd 启动的 LaunchDaemon，通过 unix domain socket 提供只读查询。
- **安全边界**（按已定决策）：只接受固定的动作枚举（"取功耗"），**不接受客户端传入任意命令行、参数或路径**（否则 root helper 立刻变成任意命令执行）；校验对端 uid 为登录用户；socket 仅属主可读写（权限 0600）；每次查询写审计日志；不接受任何写操作。
- 功耗来自 `powermetrics --samplers cpu_power --show-extra-power-info -f plist`（plist 为 NUL 分隔，键 `cpu_power`/`gpu_power`/`ane_power`/`combined_power`）。
- 协议：请求/响应格式自定（建议 JSON 行），要能区分"取不到"与"读取失败"；实现超时、重连与健康检查。
- 缓存与节流：1s 采样直接 fork powermetrics 太重——helper 内部自己维持一条 `powermetrics` 长驻采样流（或按固定间隔缓存），客户端只是取最近一次快照；采样间隔与缓存时长写进文档。
- 生命周期：开机自启、异常退出后由 launchd 拉起、卸载时干净移除（socket 文件、日志、plist）。
- 降级：helper 没装/没跑/超时 → app 侧功耗显示"不可用 + 原因"，其余指标不受影响。

产出：helper 源码 + LaunchDaemon plist 模板 + 安全说明（在 `docs/` 写明威胁模型、允许的动作枚举，以及"为什么不把整个 app 跑在 root 下、为什么不装第三方二进制"）。
