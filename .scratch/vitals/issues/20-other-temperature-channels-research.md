Type: research
Status: open
Blocked by: none

# 还有没有别的数值温度通道

## Question

在 macOS 27 / Apple M6 上，除 IOReportHub（票 01）之外，**还有没有别的路**能拿到 CPU die 的数值 °C？逐条探明并给出"能/不能"：

1. **`/usr/libexec/thermalmonitord`**：该守护进程内部符号含 `getTemperatureFromSMCForKey:`、`temperatureForKey:`、`thermalPressureLevel`、`thermalState`——说明它**确实**以特权方式读到了温度。查清它是否暴露可查询的接口：XPC service（mach service 名、`launchctl print` 里的 MachServices）、plist/文件输出、通知（notify(3) 名）、unix socket、或可被 `launchctl`/`launchctl print system` 观察到的 IPC 端点。若存在可读的 XPC 接口，能否在无特权客户端里拿到温度。
2. **重新逆向 `AppleSMCKeysEndpoint`**：之前只按**经典** SMC 协议去试（`SMCKeyData_t` + selector 2），结果一律 kIOReturnBadArgument。新端点可能换了结构布局或 selector 语义——试 selector 0/1（已知对任意 size 都返回成功）、其它 selector 组合、不同的 struct 布局与 key 编码（char0 在低字节）、以及 `IOConnectCallMethod`/`IOConnectCallScalarMethod` 的其它参数形态。目标是判断"新端点是否仍能读出温度键"。
3. **其它面**：系统守护进程里是否还有别的温度消费者（枚举 `/usr/libexec`、`/usr/lib`、`/System/Library/PrivateFrameworks` 中含 thermal/temperature 语义的组件与它们暴露的 IPC）；IORegistry 里是否有任何节点以属性形式暴露温度（上轮 ioreg 只查了 AppleSMC 类，需扩查 `IOPlatformExpertDevice` 之外的所有节点与 `Thermal`/`Temperature` 键）；`/var/run`、`/private/var/db` 等是否有温度缓存文件。

产出要求：

- 对三条路径各给一句结论（能/不能/被权限挡住/接口不存在），能的那条要给出**可运行的最小复现代码**与真实输出。
- 若三条都不通，明确写"数值 °C 在本机无路可走"，并把收敛建议给到票 04（降级为热压力四档 + 明确告知用户）。
- 探查必须遵守：无特权优先；`sudo` 在本会话沙箱内不可用（`/usr/bin/sudo` 报 "Operation not permitted"），不要尝试提权；若某条路径必须 root 才可验证，就写出需要用户在普通 Terminal 执行的确切命令，并说明预期结果。
- 不要修改工作区与 /tmp 之外的任何东西。

产出：`research/other-temperature-channels.md`（含命令、源码、原始输出片段）。
