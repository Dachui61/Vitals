Type: task
Status: open
Blocked by: 06, 21, 22

# 特权组件（LaunchDaemon + 本地 socket）

## Question

实现自研的特权组件，作为**可选**组件提供**CPU 温度**（若票 22 验证通过）与**功耗数据**（CPU/GPU/ANE 功率 mW）。

**用途的演变**（读票 02 与 20 的结论再动手）：
- 温度**不能**靠 powermetrics：macOS 27 已无 smc sampler（票 02），root 也拿不到 die 温度。
- 但 `AppleSMCKeysEndpoint` 的协议已被完整还原（票 20）：`IOServiceMatching("AppleSMC")` → `IOServiceOpen(type 0)` → `IOConnectCallScalarMethod(sel 0)` → `IOConnectCallStructMethod(sel 2, 168B → 168B)` → `IOConnectCallScalarMethod(sel 1)`；请求布局 `+0x00` key 4CC（char0 在低字节）、`+0x1c` key 字节数、`+0x2a` 命令字节（取数用 6）、`+0x30` 起 key 字符，**总长必须正好 168 字节**。无特权调用返回 `kIOReturnNotPrivileged`（授权在查键之前），root 是否放行由票 22 实测。
- 所以本组件要**直接实现这套协议**，而不是去 fork `powermetrics`——这也正好让"键名白名单"重新变得有意义（白名单 = 已验证的键，如 TC0P 等）。
- 功耗是附带能力（`powermetrics --samplers cpu_power --show-extra-power-info -f plist`），与温度走不同的实现路径，不要混在一个请求里。

**先决**：本票是否还成立，取决于票 21（要不要装特权组件）与票 22（root 到底放不放行）。若 22 结论是"不放行"，温度这半边作废，只剩功耗；若 21 决定不装，本票整体作废并从地图上删掉。

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
