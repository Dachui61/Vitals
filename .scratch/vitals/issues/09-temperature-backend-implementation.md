Type: task
Status: open
Blocked by: 04, 08

# 温度后端实现

## Question

按 04 选定的后端，在 `VitalsCore` 里实现数值 CPU 温度采集，并接进统一的数据模型。

要交付：

- 温度 provider 实现（04 选定的那条或那几条路径），遵守 04 的降级契约：不可用时返回"不可用 + 原因"，**绝不返回假温度**。
- **后端是 `/usr/lib/libSMC.dylib`（无特权）**：dlopen + `SMCOpenConnectionWithDefaultService` / `SMCReadKeyAsNumeric` / `SMCGetKeyInfo`；键打包是**大端**（`'T'<<24|'C'<<16|'0'<<8|'P'`），与旧 IOKit 端点的低字节序**不要混用**；单次读 ~100 µs。已有可复用实现：`scratch/smc_temp.swift`。
- **不要**实现"特权 helper 读温度"这条路径：票 02 已证明 macOS 27 的 powermetrics 不再提供 smc sampler；票 01 又证明无特权的 libSMC 就能读到数值温度，root 没有必要；票 21 已决定不装特权组件。
- **不要**走 IOReportHub 路线：票 01 已证明 macOS 27 的 IOReport 通道空间里没有 CPU die 温度通道，且原始样本缓冲区在本机被 KERN_NO_SPACE 挡住。
- 能力探测要覆盖：dlopen(`/usr/lib/libSMC.dylib`) 失败、符号缺失、连接打开失败、键不存在（rc=-3）、读值越界（不在合理温度区间）——任一情况都要能干净地退到 thermalState 四档，并让界面同步显示"不可用 + 原因"。
- 读数若属"推断"出的 CPU die 键，要按 GLOSSARY 带上**近似值**标记与**传感器名**（票 04 定的规则）。
- **主键与降级链（票 23 定案）**：主用 `Tp0j`；降级顺序 `Tp0j → Tp0g → Tp09 → Tp07 → Tp0b → Tp05 → Tp0m → Tp0L`。**不要**用 `TH0x`/`TH0a`/`TH0b`/`TMVR`（环境/板级，CPU 负载下不动）；**不要**用 `Tg*`（GPU 侧）；**不要**用 `TVD0/TVDC/TVDP/TCMb`（SoC 封装热点，不是 CPU die）。
- libSMC 支持**全量枚举**：`_SMCGetKeyFromIndex(conn, index, &outKey)`（可复用 `scratch/smc_keys.swift`），本机 2066 键，温度键在 index 556–703。探针策略按票 04 的结论实现。
- 键名在各机型上会变 → 读到的键名要原样带进界面（如「SMC Tp0j」），不要硬编码成"CPU 温度"了事。
- 能力探测：启动时与运行期判断后端可用性（IOReportHub 通道是否存在 / helper 是否在跑 / socket 是否可连），探测失败要能自动降级到 thermalState 四档并让界面同步更新。
- 传感器名：展示实际读到的传感器名；多候选键时按 04 定的优先级选择。
- 可信度标注：无特权近似的读数必须带"近似"标记；特权读数标注来源。
- 单元测试：后端可用/不可用两种分支、候选键优先级、温度合理性区间校验（如 0–120°C，超界视为无效读数并降级）。

产出：实现 + 测试 + 在本机实跑的读数样本（贴进 `docs/` 的实测记录）。
