Type: task
Status: open
Blocked by: 04, 06

# 特权 helper（LaunchDaemon + 本地 socket）

## Question

实现自研的特权 helper，作为**可选**组件为数值温度提供数据（若 04 选定了特权路线）。

要交付：

- `VitalsHelper`：以 root 身份由 launchd 启动的 LaunchDaemon，通过 unix domain socket 提供只读查询。
- **安全边界**（按已定决策）：键名白名单（只接受预先批准的键，拒绝任意键名）；校验对端 uid 为登录用户；socket 仅属主可读写（权限 0600）；每次查询写审计日志；不接受任何写操作。
- 协议：请求/响应格式自定（建议 JSON 行），要能区分"无此传感器"与"读取失败"；实现超时、重连与健康检查。
- 缓存：同一键短时间内可缓存，避免 1s 采样把 helper 打爆（缓存时长写进文档）。
- 生命周期：开机自启、异常退出后由 launchd 拉起、卸载时干净移除（socket 文件、日志、plist）。
- 降级：helper 没装/没跑/超时 → app 侧走 04 定的降级路径，界面明确说明原因。

产出：helper 源码 + LaunchDaemon plist 模板 + 安全说明（在 `docs/` 写明威胁模型与白名单内容）。
