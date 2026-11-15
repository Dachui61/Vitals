# Vitals 规格

macOS 菜单栏 + 悬浮窗的电脑健康监控工具。本文档是实现的依据；术语一律见 [GLOSSARY.md](../GLOSSARY.md)，决策理由见 [adr/](adr/)。

## 1. 目标与非目标

**目标**：一台 Mac mini（Apple M6 / macOS 27）上的常驻小工具，随时能看到这台机器的健康状况：CPU 占用（总量与每核）、CPU 核心温度、SoC 封装热点、内存、电源状态。

**非目标（v1 明确不做）**：

- 远程监控、告警外发（本机通知 בלבד）
- 多机/多用户管理
- Intel Mac 兼容（只支持本机 Apple Silicon）
- 电池与耗电指标（本机无电池；CPU/GPU 功耗需要特权，已随"不引入特权组件"一并出局）
- GPU 温度（macOS 27 上没有任何可达路径）
- "显存"占用（统一内存机器上没有显存；改称"GPU 占用系统内存"，属 v2）

**v2 增量**：GPU 占用、GPU 占用系统内存、磁盘读写速率、网络上下行速率、进程 Top 5。

## 2. 用户可见行为

### 2.1 菜单栏

- 图标：SF Symbol `waveform.path.ecg`（模板图，跟随系统深浅）。
- **迷你读数**：`CPU% · 核心温度 · 内存%`，每秒刷新；某项不可用时该位显示 `—`。
- 菜单项：显示悬浮窗 / 隐藏悬浮窗 / 透明度滑块（20%–100%，实时生效）/ 启用告警 / 温度阈值（70/75/80/85/90 °C）/ CPU 阈值（80/85/90/95 %）/ 退出 Vitals。
- 所有设置写入 `UserDefaults`。

### 2.2 悬浮窗

- 无边框、置顶、可拖到任意显示器、可缩放到任意大小（最小 230×34）。
- **拖动**：面板主体任意位置按下拖动即可移动窗口（右上角关闭按钮与右下角缩放握把除外，那两处留给自己的控件）。窗口**精确跟随光标**（逐帧无迟滞）。因此面板内的**滚动要用滚轮/触控板双指**，拖动专用于移动窗口。
- **内容按尺寸分档**（宽、高各算一个允许的最高档，取小者；高度不够就退档，不裁切）：

| 档 | 宽度 | 高度下限 | 内容 |
|---|---|---|---|
| L0 | < 320 | ≥ 46 | 一行文字：`CPU 13% · 温度 57° · 内存 63%` |
| L1 | < 520 | ≥ 120 | 小卡片：CPU / 核心温度 / 内存 |
| L2 | < 700 | ≥ 200 | 小卡片：电源 |
| L3 | < 880 | ≥ 400 | 核心温度卡（大数字 + SoC 热点 + 热压力等级 + 阈值带） |
| L4 | < 1080 | ≥ 660 | （v2）进程 Top 5 |
| L5 | ≥ 1080 | ≥ 660 | 每核占用（12 条曲线） |

- 视觉：主题跟随系统浅/深；**背景透明度可调而文字始终 100% 不透明**；每核曲线按核型着色（超频=橙红 / 性能=蓝 / 能效=绿）；温度 ≥70 °C 数字转黄、≥80 °C 转红，阈值带同步变色。
- 核心温度显示为 `56.8 °C`，下方标注 `SMC Tp0j · 近似值`；SoC 热点同理（`SMC TVD0 · 近似值`）。
- **热压力等级独立成行**，四档，**不叫"温度"**。
- 任何指标不可用时显示「不可用 + 原因」，**不显示 0、不隐藏原因**。

### 2.3 告警

- 温度：取核心温度与 SoC 热点中**较高且可用**的那个 ≥ 阈值（默认 80 °C）。
- CPU：≥ 阈值（默认 90%）并**持续 30 秒**。
- **边沿触发 + 冷却**：持续高温只发一次；回落到阈值以下、再次冲高且冷却期（10 分钟）已过才重发。
- 温度不可用时不触发温度告警（也不谎称正常）。
- 通知走系统通知；**授权被拒时退化为悬浮窗内横幅**。

## 3. 数据模型与口径

| 指标 | 口径 | 来源 |
|---|---|---|
| CPU 占用 | (user + sys + nice) / 总计，idle 之外都算忙；**tick 比例 100/s** | `host_processor_info` |
| 核型 | 设备树 `cluster-type`（E=能效 / P=超频 / M=性能），按数量唯一配对 | IOKit 设备树 |
| 已用内存 | (active + inactive − purgeable) + wired + compressed，**含 file-backed**，与 `top` 的 `PhysMem: used` 同口径 | `host_statistics64`（见 §5 的坑） |
| 内存压力 | 四档位掩码 1/2/4 | `kern.memorystatus_vm_pressure_level` |
| swap | 单位是**字节** | `vm.swapusage` |
| 核心温度 | 主键 `SMC Tp0j`，降级链 `Tp0g → Tp09 → Tp07 → Tp0b → Tp05 → Tp0m → Tp0L` | `/usr/lib/libSMC.dylib` |
| SoC 热点 | `SMC TVD0` | 同上 |
| 热压力等级 | 四档 | `ProcessInfo.thermalState` |
| 电源 | 外接电源 / 电池（本机为前者） | `AppleSmartBattery` |

**可信度**：核心温度与 SoC 热点都是**近似值**（键语义靠负载相关性推断，且无法交叉验证）→ 界面必须标注「近似值」+ 传感器名。

## 4. 采集架构

```
MetricsEngine（1 Hz Timer，主 RunLoop .common 模式）
  ├─ CPUProviderImpl      ── host_processor_info + 差分基准（第一帧无基准，显示"正在识别…"）
  ├─ MemoryProviderImpl   ── host_statistics64 + 两个 sysctl
  ├─ PowerProviderImpl    ── AppleSmartBattery
  ├─ ThermalStateProviderImpl ── ProcessInfo.thermalState
  ├─ TemperatureProviderImpl  ── libSMC 直读 Tp0j（+ 降级链）
  └─ SoCHotspotProviderImpl   ── libSMC 直读 TVD0
        ↓ CoreSnapshot（不可用时带原因）
     PanelViewModel（@Published）→ 悬浮窗 SwiftUI / 菜单栏读数 / AlertEngine
```

- **UI 只读快照，不触发采集。**
- 某个 provider 失败只影响它自己那一个指标。
- 历史：每核 60 秒滚动窗口（1 Hz）+ 10 分钟粗粒度（每 10 秒一点），全在内存，重启清空。
- 平滑用 3 点滑动平均；**告警判定用原始值**（EMA 的滞后会让告警误触发）。
- 采样本身的开销：v1 全套约 12 µs/次（采样周期的 0.0012%）。

## 5. 降级链

```
libSMC 读 Tp0j（及降级键）→ 失败则 ProcessInfo.thermalState 四档 → 再失败则「不可用（原因）」
```

- 温度**不可用**时不编造数字、不用等级反推温度。
- 惰性探测：连续 3 次读不到才在后台做一次探测（枚举 `T*` 候选 → 1.5 s 单线程 userInteractive 负载 → 取涨幅最大的键），结果连同机型与系统版本落盘缓存；探测期间显示「正在识别…」。

### 已知的坑（实现必须遵守）

1. `host_processor_info` 返回的数组由内核分配，**必须 `vm_deallocate`**，否则每秒漏 384 B。
2. tick 比例是 **100/s**（不是 1000/s）——换算 CPU 秒时用 100。
3. **`host_statistics64` 返回的长度不可靠**：同一二进制里独立编译的进程拿到 104 个 4 字节整数，SwiftPM 构建只拿到 40 个 → 照返回长度拷贝会静默少读一大半字段（曾把内存显示成 4.9 GB，真值 14.6 GB）。实现只用**经验验证过的原始整数下标**并做合理性校验。
4. 设备树节点不在 service plane 里，要用 `IORegistryEntryCreateIterator` + 显式 plane。
5. `vm.swapusage` 的单位是字节；`host_statistics64` 的计数可能回绕，差分要用 `&-` 并判为不可比。
6. GPU 的 `PerformanceStatistics` 每 ~250 ms 会整组掉 0 → 连读 3 次取最大。
7. 网络吞吐必须排除 `lo0`（否则几十 GB 的背景流量淹没真实值）。
8. **不得 fork 子进程取数**（`iostat` 1075 ms、`pmset` 76 ms）。

## 6. 权限与安装

- **不引入任何特权组件**：没有 root 守护进程、没有 unix socket、没有审计日志。
- 安装：双击 `build/Vitals.pkg` → `~/Applications/Vitals.app` + `~/Library/LaunchAgents/local.vitals.app.plist`（用户域，**不需要管理员密码**）。
- 卸载：`./scripts/uninstall.sh --apply`。

## 7. 构建与验证

```bash
./scripts/build.sh     # 产出 build/Vitals.app
./scripts/test.sh      # 单元测试（24+ 用例）
./scripts/package.sh   # 产出 build/Vitals.pkg
VITALS_LIVE=1 swift run VitalsCoreTests   # 真机采样检查：打印实际读数
```

## 8. 验收

见 [acceptance.md](acceptance.md)（六组 30 条，含每条的验证步骤与通过阈值）。执行结果见 `acceptance-report.md`（票 18 产出）。

## 9. 相关决策

- [ADR 1：温度后端与降级策略](adr/0001-温度后端与降级策略.md)
- [ADR 2：为何不引入特权组件](adr/0002-为何不引入特权组件.md)
- [ADR 3：私有接口的使用与降级](adr/0003-私有接口的使用与降级.md)
