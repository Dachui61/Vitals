Type: research
Status: resolved
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

## Answer

**结论：无特权下本机不存在任何数值 °C 通道（三条路全走完）；但 SMC 端点的协议已被完全还原，取数被"调用者身份"挡住 —— root 很可能放行，这条路值得验证。**

三条路径：

1. **`/usr/libexec/thermalmonitord` → 接口不存在。** 它的 launchd plist 里没有 MachServices，二进制里没有可连接的 XPC mach service（`com.apple.*` 全是 dispatch queue / 通知名），唯一的 notify 是压力等级（`kOSThermalNotificationPressureLevelName`），`/var/log/smcKeys.csv`、`/var/log/tgraph.csv` 都不存在。它内部真正读温度用的 `AppleSMCSensorDispatcher`（`IOUserClientCreator = pid 112, thermalmonitord`）user-client type 0…65535 **全部打开失败**（BadArgument）——无可借道。
2. **`AppleSMCKeysEndpoint` → 协议还原完成，取数被权限挡住。** 从 thermalmonitord 反编译出真实调用序列：`IOServiceMatching("AppleSMC")` → `IOServiceOpen(type 0)` → `IOConnectCallScalarMethod(sel 0)` → `IOConnectCallStructMethod(sel 2, 168B → 168B)` → `IOConnectCallScalarMethod(sel 1)`。请求布局：**恰好 168 字节（0xa8）**，请求与输出同长；`+0x00` = key 4CC（`'T'|'C'<<8|'0'<<16|'P'<<24`，char0 在**低**字节）；`+0x1c` = key 字节数；`+0x2a` = **命令字节**（thermalmonitord 用 6）；`+0x30` 起 = key 字符。实测：长度必须正好 168（经典 132 字节 `SMCKeyData_t` 必然 BadArgument）；命令字节 0…4 → BadArgument；5/7/8/9/12/17 → OK 但只回 `00 01 02 …` 的 echo；**6（唯一取数据的命令）→ kIOReturnNotPrivileged**。授权检查发生在**查键之前**（不存在的键 `XXXX` 报同一个错）——**格式对了，是调用者身份被拒**。
3. **其它面 → 不能。** 全量 `ioreg -l -w0`（40315 行）无任何数值温度属性（唯一叫 `TemperatureSensor` 的是"板型→PMU 传感器名"字典，无数值）；42 个 `AppleARMPMUTempSensor` 是 `PMU tcal`/`PMU tdevN` **校准/偏置**传感器，只暴露 HID 事件服务入口；`AppleEmbeddedNVMeTemperatureSensor` 是 SSD 温度不是 CPU；`pmset -g thermlog` 无特权零输出（pmset 自带 "Must be run as root"），`pmset -g therm` 只给等级；`/var/db`、`/var/run`、`/var/log/powermanagement/*.asl` 全无温度数据。附带一个负结果：`SMCT.framework`（`com.apple.ggd.SMCT`）名字像 SMC，其实是图像库。

对票 04 的收敛建议：

- 候选表收敛为：(a) IOReportHub 归票 01；(b) 组合——本票没提供任何可进组合的路；(c) thermalState 四档是本票唯一支持的结论。
- **但新增一个候选**：阻断点是 `kIOReturnNotPrivileged`（调用者授权），root 很可能被放行——票 02 只否定了 powermetrics 这个**工具**，没有否定 SMC 端点本身。协议已还原，可直接给用户一条 root 验证命令（见新票 22）。
- **降级契约措辞**（按 GLOSSARY）：核心温度显示"不可用（原因：本机未向无特权应用开放温度传感器）"，**不显示 0、不用等级反推数字**；热压力等级作为独立一行、四档、**不叫"温度"**；温度类阈值告警按"不可用"处理而非静默不触发；等级类告警保留。
- **能力探测**必须运行时做 + 超时 + 子进程崩溃隔离（错误长度可能崩）；后端顺序 A(IOReportHub 私有协议) → B(特权组件，若安装) → C(thermalState 四档)；每级"试一次就知道行不行"，不写死版本号。
- 若最终只能 C，必须**显式记为对 v1 需求的让步**。建议文案：`核心温度  不可用（macOS 未向无特权应用开放温度传感器）  ·  热压力等级  正常`。

开放问题：① root 下 SMC 是否放行（**需用户验证**，见票 22）；② 票 01 的 IOReportHub 结论（若有数值温度，本票结论要改写）；③ `AppleSMCSensorDispatcher` 的 user-client type 到底是什么（0…65535 全败）；④ 命令字节 5/7/8/9/12/17 返回的 `00 01 02 …` 是不是某种能力/版本查询。

完整报告：[research/other-temperature-channels.md](../../research/other-temperature-channels.md)（分支 `research/other-temperature-channels`）；探针源码 `scratch/t20_smcproto.swift` 等在 gitignored 的 `scratch/`，已复制到分支的 `research/probes/`。
