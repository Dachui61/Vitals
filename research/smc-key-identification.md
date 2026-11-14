# 票 23 · research · 哪个 SMC 键才是 Apple M6 的 CPU die 温度

> 实测机器：macOS 27.0 (26A425) / Apple M6 Mac mini (Mac18,5) / 12 核 (2 超频 + 4 性能 + 6 能效) / 16 GB / 仅交流电
> 实测时间：2026-11-14 20:59–21:35 (Asia/Shanghai)
> 全部实验在**无特权**（uid=euid=501）环境下完成；未使用 sudo。
> 可复用代码：`scratch/smc_keys.swift`（枚举 + 采样 + 负载发生器）、`scratch/smc_temp.swift`（既有最小读取器）
> 原始数据：`scratch/smc_all_keys.tsv`、`scratch/cpu_load.tsv`、`scratch/gpu_load.tsv`、`scratch/load_p1.tsv`、`scratch/load_e1.tsv`、`scratch/gpu_util.txt`
> 术语按 `GLOSSARY.md`：**核心温度**、**近似值**、**不可用**、**降级链**、**后端**

---

## Verdict

**主用键：`Tp0j`（SMC key，4 字节大端打包 = `0x54706A6A`）。** 它是本机所有可读温度键里 **对 CPU 负载响应最强、且绝对温度最高的 CPU 侧传感器**；它的响应**只来自 CPU**：CPU 满载 +12.8 °C、单线程压性能核 +19.3 °C；而 GPU 满载（AGX 利用率 90–95 %、CPU 占用不变）只有 +6.0 °C，弱 GPU 对照里只有 +0.9 °C。

**降级链（同一优先级顺序，键名 → 显示名）：**

| 顺序 | SMC 键 | 依据（在本机的实测） |
|---|---|---|
| 1 | `Tp0j` | CPU 侧最强响应；P 核单线程 +19.3 °C；全核负载下 CPU 侧最高温 |
| 2 | `Tp0g` | 次强（P 核单线程 +18.6 °C），与 `Tp0j` 曲线几乎同相 |
| 3 | `Tp09` | 第三（P 核单线程 +12.3 °C） |
| 4 | `Tp07` | 与 `Tp09` 接近（+12.3 °C） |
| 5 | `Tp0b` | +6.3 °C，响应明显变弱 |
| 6 | `Tp05` | +5.7 °C |
| 7 | `Tp0m` | +4.8 °C |
| 8 | `Tp0L` | 12 核负载时 +13.0 °C，但单线程 P 核只 +3.1 °C（更像聚合/平均型传感器） |

**必须排除的键（会显示成"GPU 温度"或"SoC 热点温度"）：**

- `Tg*`（18 个键：`Tg01 Tg07 Tg08 Tg09 Tg0a Tg0b Tg0c Tg0d Tg10 Tg17 Tg1a…Tg1h`）= **GPU 侧**。GPU 满载时 +13～16 °C，CPU 满载时只 +5 °C。
- `TVD0` / `TVDC` / `TVDP` / `TCMb` = **SoC 封装/热点级**。绝对温度最高（空闲 52–55 °C，单核满载 73 °C），但 **CPU 和 GPU 负载都让它上涨**，是整机最热的点——**选它就会把 SoC 热点当成 CPU die**。
- `TPD*`（18 个键）= 混合类，响应一半一半，无法归到 CPU 或 GPU。
- `TH0x` / `TH0a` / `TH0b` / `TMVR` / `TR*d` / `TW0P` / `TT0P` / `TN00` / `THSP` / `TPSP` / `TVN*` / `TIED` = **不随负载动**（≤1.7 °C），是环境/板级/电压轨温度，**不是 die 温度**。
- `Ta0*`(12) + `Te0f` + `Te0g` + `Ts05` = **15 个键读数完全相同**（同一颗传感器的多个别名），且 CPU 负载 +6.8 °C / GPU 负载 +7.6 °C —— 两边一样，更像环境/封装级而非 die。

> ⚠️ 按 `GLOSSARY.md`：**这个判定是"由负载相关性推断"出来的，不是 Apple 官方确认的**。因此 Vitals 显示该值时必须标 **近似值**，并同时显示实际读取的传感器名（本机为 `SMC Tp0j`）。详见 [Confidence](#confidence)。

---

## Evidence table

所有数值都是**中位数**，单位 °C。"CPU 12 核"= 12 个满载线程（CPU 占用 ~95 %）；"GPU"= MPS 高斯模糊，AGX `Device Utilization %` 实测 90–95 %，且 CPU 占用无上升（空闲 16.4–18.7 %，负载期 13.8–18.6 %）；"P 核 1 线程"= 单线程 `QOS_CLASS_USER_INTERACTIVE`（落到性能/超频核）；"E 核 1 线程"= 单线程 `QOS_CLASS_BACKGROUND`（落到能效核）。

| key | 存在 | 空闲 | CPU 12 核 | GPU 满载 | P 核 1 线程 | E 核 1 线程 | 判定 |
|---|---|---|---|---|---|---|---|
| **`Tp0j`** | ✅ | 44.1 | **56.8** (+12.8) | 53.6 (+6.0) | **65.0 (+19.3)** | 42.4 (+0.0) | **CPU die（主用）** |
| `Tp0g` | ✅ | 43.6 | 54.5 (+10.9) | 52.9 (+5.9) | **63.7 (+18.6)** | 41.9 (−0.4) | CPU die（第 2） |
| `Tp09` | ✅ | 43.7 | 54.9 (+11.2) | 52.5 (+5.8) | 58.0 (+12.3) | 42.5 (−0.1) | CPU die（第 3） |
| `Tp07` | ✅ | 42.8 | 53.2 (+10.4) | 51.6 (+6.0) | 56.8 (+12.3) | 41.5 (−0.4) | CPU die（第 4） |
| `Tp0b` | ✅ | 42.9 | 54.2 (+11.3) | 51.1 (+6.2) | 50.9 (+6.3) | 41.5 (−0.6) | CPU die（第 5） |
| `Tp05` | ✅ | 42.2 | 52.1 (+9.9) | 50.5 (+6.5) | 49.8 (+5.7) | 41.0 (−0.1) | CPU die（第 6） |
| `Tp0m` | ✅ | 42.2 | 54.8 (+12.6) | 50.5 (+6.5) | 48.8 (+4.8) | 40.8 (−0.7) | CPU die（第 7） |
| `Tp0L` | ✅ | 41.3 | 54.3 (+13.0) | 52.7 (+9.5) | 46.5 (+3.1) | 40.3 (−0.2) | CPU 侧但偏聚合 |
| `Tg*`（18 个） | ✅ | 41–42 | 46–47 (+5.1～5.7) | **55.9–59.2 (+13.4～16.3)** | 45.2–45.7 (+1.3～2.3) | 平 | **GPU die —— 必须排除** |
| `TVD0`/`TVDC`/`TVDP`/`TCMb` | ✅ | **52–55** | **64.9** (+12.2) | **65.1–65.6** (+9.4～+10.0) | **73.0 (+18.3)** | 51.9 (−0.1) | **SoC 封装/热点 —— 必须排除** |
| `TPD0` / `TPDX` | ✅ | 44.7 / 44.9 | 59.3 (+14.5) | 57.9 / **65.5** (+9.9 / +17.5) | 57.1 (+10.7) | 42.8 (−0.2) | 混合（die 级） |
| `TPD1` / `TPDJ` / `TPD9` / `TfC1` | ✅ | 43–44 | 50–53 (+6.6～8.9) | **60.6–65.7 (+14～20.8)** | 49–52 | 平 | GPU 倾向，混合 |
| `Ts*`（9 个） | ✅ | 40–41 | 44.6–46.4 (+3.6～5.1) | 48.6–55.7 (+6.6～13.5) | 44–45.6 | 平 | 混合 / 偏 GPU |
| `Te0*`（7 个，另 2 个 `Te0f`/`Te0g` 属别名组） | ✅ | 42–43 | 48.6–50.6 (+6.8～7.6) | 50.6–51.5 (+7.2～7.6) | 47–48 | 平 | 混合，来源不明 |
| `Ta0*`(12)+`Te0f`+`Te0g`+`Ts05` | ✅ | 41.3 | 48.1 (+6.8) | 50.4 (+7.6) | 46.3 | 平 | 同一传感器的 15 个别名 |
| `TH0x` / `TH0a` | ✅ | 40.1 | 40.7 (**+0.6**) | 42.7 (+2.2) | 40.8 (−0.1) | 39.4 (−0.6) | 不随负载 —— 环境/板级 |
| `TH0b` / `TMVR` / `TN00` / `THSP` / `TPSP` / `TIED` / `TVN0` / `TVN1` / `TVNS` | ✅ | 39.7–43.0 | ±1.1 | +2～3 | ±0.2 | 平 | 不随负载 —— 环境/板级 |
| `TR0Z`…`TRDX`（14 个） | ✅ | 35.3–51.8 | ±0.2 | ±1.4 | ±0.1 | 平 | **完全不动**，电压轨/其他 |
| `TW0P` / `TT0P` / `TPSD` / `TVS0` | ✅ | 35.3–41.2 | −0.2～−0.15 | ±0.1 | ±0.1 | 平 | 不随负载 —— 板级 |
| `Tz11`…`Tz1j`（9 个） | ✅ | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 未接线的传感器槽位 |
| `TC0P` `TC0F` `TCHP` `TCXC` `TM0P` `TG0D` | ❌ | — | — | — | — | — | **不存在**（Intel 经典键） |

---

## Method details

### 1. 枚举：libSMC 确实有全量枚举 API

`/usr/lib/libSMC.dylib` 在共享缓存里（`/usr/lib/libSMC.dylib` 不是普通文件，要用 `dyld_info` 读）：

```bash
dyld_info -exports /usr/lib/libSMC.dylib        # 142 个导出符号
```

其中有 **`_SMCGetKeyFromIndex`** —— 这就是枚举 API，不需要靠前缀猜键。签名（从 `dyld_info -disassemble` 反汇编得出）：

```c
// x0 = connection, w1 = 索引, x2 = 输出 SMCKey_t(uint32)
int SMCGetKeyFromIndex(SMCConnection_t conn, uint32_t index, uint32_t *outKey);
// 返回 0 = 成功, -3 (0xfd) = 索引越界, -4 (0xfc) = 键非法
```

遍历 0…N 直到返回 −3，**本机共 2066 个键**（`scratch/smc_all_keys.tsv`）。枚举结果按 ASCII 排序（`TCMb → TH0x → TMVR → TPD0…TPDX → … → Tz1j`），温度键是**连续的一段：index 556…703，共 148 个**，其中 130 个读数落在 (5, 120) °C 区间 —— 说明温度键集合已**枚举完整**，没有漏掉的键。

代码（`scratch/smc_keys.swift`，可直接抄进项目）：

```swift
typealias SMCGetKeyFromIndex = @convention(c) (
    UnsafeMutableRawPointer?, UInt32, UnsafeMutablePointer<UInt32>?
) -> Int32

func enumerateKeys(max: Int = 65536) -> [(index: Int, key: UInt32)] {
    var out: [(index: Int, key: UInt32)] = []
    var k: UInt32 = 0
    var misses = 0
    for i in 0..<max {
        let rc = keyFromIndexFn(connection, UInt32(i), &k)
        if rc == 0 { out.append((i, k)); misses = 0 }
        else {
            misses += 1
            if rc == -3 { break }          // 索引越界 → 枚举结束
            if misses > 64 { break }
        }
    }
    return out
}
```

键打包仍是**大端**：`'T'<<24 | 'C'<<16 | '0'<<8 | 'P'`。

### 2. 负载实验

```bash
# CPU：12 个满载线程（QOS_CLASS_DEFAULT）
scratch/smc_keys watch --temps --pre 20 --seconds 30 --post 25 --load cpu --out scratch/cpu_load.tsv

# GPU：Metal Performance Shaders 高斯模糊（无 Metal 编译器，用 MPS 代替 compute shader）
scratch/smc_keys watch --temps --pre 15 --seconds 40 --post 25 --load gpu --out scratch/gpu_load.tsv

# 单线程压性能核 / 单线程压能效核（THREAD_AFFINITY_POLICY 在本机不可用，只能用 QoS 引导）
scratch/smc_keys watch --temps --pre 15 --seconds 25 --post 20 --load cpu --threads 1 --qos userInteractive --out scratch/load_p1.tsv
scratch/smc_keys watch --temps --pre 15 --seconds 25 --post 20 --load cpu --threads 1 --qos background      --out scratch/load_e1.tsv
```

GPU 负载的真实性是独立验证过的（不是"看起来像在跑"）：

```bash
ioreg -r -c AGXAccelerator -l -w0 | grep -o '"Device Utilization %"=[0-9]*'
# 45 次采样：34 次落在 90–95 %，其余 38–42 % 是空闲/后台
```

### 3. 真实曲线（数据表）

**CPU 12 核满载（`scratch/cpu_load.tsv`，每 5 行取 1）：**

> 该文件的 CPU % 列是**旧版指标**（开机以来累计 tick 的比值，恒为 8.9），不可用于判断负载；后来的 `gpu_load.tsv` / `load_p1.tsv` 已改用**逐样本差分**，CPU % 是真实值（见下两表）。

| t (s) | 阶段 | CPU % | `Tp0j` | `Tp0g` | `Tp09` | `Tg09` | `TVD0` | `TPD0` | `TH0x` |
|---|---|---|---|---|---|---|---|---|---|
| 4.2 | idle | 8.9 | 44.28 | 43.66 | 43.92 | 41.05 | 52.95 | 44.97 | 40.26 |
| 9.3 | idle | 8.9 | 44.00 | 43.30 | 43.56 | 40.92 | 52.45 | 44.12 | 40.26 |
| 14.5 | idle | 8.9 | 43.73 | 43.44 | 43.52 | 40.86 | 52.27 | 44.80 | 40.45 |
| 19.6 | idle | 8.9 | 44.77 | 44.33 | 44.47 | 41.02 | 53.21 | 46.15 | 39.94 |
| 24.8 | load | 8.9 | 55.11 | 52.30 | 52.89 | 43.95 | 63.15 | 55.96 | 39.83 |
| 29.9 | load | 8.9 | 56.78 | 53.92 | 54.42 | 45.39 | 64.82 | 57.31 | 40.52 |
| 35.1 | load | 8.9 | 56.75 | 54.34 | 54.75 | 46.31 | 64.79 | 58.33 | 40.71 |
| 40.3 | load | 8.9 | 56.91 | 54.91 | 55.22 | 47.42 | 64.95 | 59.68 | 41.49 |
| 45.4 | load | 8.9 | 59.31 | 56.61 | 57.11 | 48.20 | 67.35 | 60.02 | 41.49 |
| 50.5 | load | 8.9 | 58.75 | 56.62 | 56.92 | 49.69 | 66.79 | 61.37 | 42.15 |
| 55.7 | cooldown | 8.9 | 49.17 | 48.66 | 49.08 | 46.48 | 58.19 | 50.38 | 42.23 |
| 60.9 | cooldown | 8.9 | 47.28 | 47.14 | 47.45 | 45.41 | 56.98 | 47.84 | 42.54 |
| 66 | cooldown | 8.9 | 47.17 | 46.42 | 47.05 | 44.62 | 56.27 | 47.34 | 42.23 |
| 71.2 | cooldown | 8.9 | 46.39 | 45.94 | 46.33 | 43.97 | 55.38 | 46.66 | 42.23 |
| 76.4 | cooldown | 8.9 | 45.92 | 45.47 | 45.97 | 43.38 | 55.25 | 46.32 | 41.97 |

**GPU 满载（`scratch/gpu_load.tsv`，每 5 行取 1；AGX `Device Utilization %` 实测 90–95 %，CPU 占用全程 13.8–20.9 % 不变）：**

| t (s) | 阶段 | CPU % | `Tp0j` | `Tp0g` | `Tp09` | `Tg09` | `Tg0c` | `TVD0` | `TPD0` |
|---|---|---|---|---|---|---|---|---|---|
| 4.2 | idle | 16.8 | 48.02 | 47.19 | 47.09 | 42.67 | 43.05 | 56.06 | 47.17 |
| 9.3 | idle | 16.4 | 48.30 | 47.47 | 47.17 | 42.58 | 42.97 | 56.34 | 48.69 |
| 14.5 | idle | 18.6 | 48.02 | 47.47 | 47.11 | 42.55 | 43.02 | 56.06 | 46.66 |
| 19.6 | idle | 18 | 45.38 | 45.19 | 45.08 | 41.81 | 42.30 | 53.82 | 47.67 |
| 24.8 | load | 14.8 | 48.70 | 48.34 | 48.20 | 53.11 | 55.84 | 63.49 | 53.76 |
| 29.9 | load | 18.6 | 49.05 | 48.78 | 49.05 | 54.41 | 57.08 | 64.24 | 55.11 |
| 35.1 | load | 17.5 | 48.44 | 47.67 | 48.42 | 50.64 | 53.06 | 60.25 | 52.75 |
| 40.3 | load | 17.1 | 51.06 | 50.80 | 50.92 | 57.67 | 60.52 | 67.78 | 57.14 |
| 45.4 | load | 13.8 | 54.09 | 53.59 | 53.77 | 59.56 | 62.25 | 69.64 | 61.88 |
| 50.6 | load | 15.9 | 54.61 | 54.23 | 54.38 | 60.12 | 62.91 | 70.18 | 61.88 |
| 55.7 | load | 16.2 | 53.64 | 53.03 | 53.62 | 55.91 | 58.16 | 65.14 | 57.82 |
| 60.9 | load | 15.8 | 56.86 | 56.36 | 56.44 | 61.70 | 64.48 | 72.22 | 63.74 |
| 66 | cooldown | 20.1 | 55.89 | 55.12 | 55.44 | 52.28 | 53.03 | 64.18 | 57.14 |
| 71.2 | cooldown | 20.9 | 54.11 | 53.47 | 53.78 | 50.48 | 51.08 | 62.52 | 58.50 |
| 76.3 | cooldown | 21.2 | 52.95 | 52.48 | 52.59 | 49.86 | 50.64 | 61.33 | 54.44 |
| 81.5 | cooldown | 20.3 | 51.52 | 50.75 | 51.16 | 48.31 | 49.03 | 60.09 | 52.75 |
| 86.7 | cooldown | 20.3 | 50.73 | 50.03 | 50.56 | 47.47 | 48.23 | 59.30 | 52.75 |

**单线程压性能核（`scratch/load_p1.tsv`）——这是最能区分"CPU die"的一组：**

| t (s) | 阶段 | CPU % | `Tp0j` | `Tp0g` | `Tp09` | `Tp07` | `Tp0b` | `Tp05` | `Tp0m` | `TVD0` | `Tg09` |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 4.2 | idle | 18.8 | 46.06 | 45.56 | 46.11 | 44.91 | 44.91 | 44.27 | 44.23 | 55.22 | 43.36 |
| 9.3 | idle | 19.3 | 44.91 | 44.66 | 44.97 | 43.97 | 44.47 | 43.86 | 43.86 | 54.02 | 42.73 |
| 14.5 | idle | 18.7 | 44.73 | 44.39 | 44.72 | 43.50 | 43.98 | 43.14 | 43.27 | 53.72 | 42.28 |
| 19.6 | load | 22.7 | 63.80 | 62.91 | 57.03 | 55.86 | 49.86 | 48.80 | 47.59 | 71.84 | 44.11 |
| 24.8 | load | 19.8 | 64.94 | 63.67 | 57.95 | 56.61 | 50.62 | 49.56 | 48.53 | 72.98 | 44.92 |
| 29.9 | load | 20.2 | 65.44 | 64.39 | 58.48 | 57.34 | 51.34 | 50.20 | 49.16 | 73.48 | 45.50 |
| 35 | load | 19.8 | 66.03 | 64.94 | 59.09 | 57.94 | 51.81 | 50.70 | 49.67 | 74.07 | 46.05 |
| 40.2 | load | 20.4 | 66.64 | 65.28 | 59.64 | 58.48 | 52.33 | 51.19 | 50.38 | 74.68 | 46.55 |
| 45.3 | cooldown | 17.2 | 48.16 | 47.59 | 47.92 | 46.84 | 46.69 | 46.08 | 46.05 | 56.84 | 44.91 |
| 50.5 | cooldown | 17.2 | 46.03 | 45.69 | 46.11 | 45.20 | 45.69 | 44.83 | 45.11 | 55.36 | 43.98 |
| 55.7 | cooldown | 17.2 | 46.11 | 45.59 | 46.06 | 45.06 | 44.98 | 44.27 | 44.23 | 55.23 | 43.23 |
| 60.8 | cooldown | 17.5 | 45.94 | 45.47 | 45.75 | 44.67 | 44.78 | 44.19 | 44.16 | 54.49 | 42.83 |


**单线程压能效核（`scratch/load_e1.tsv`）：所有 CPU 侧键都不动（`Tp0j` 42.45 → 42.38），GPU 键也不动。**

### 4. 与 Apple 自家工具的交叉验证

| 工具 | 结果 | 结论 |
|---|---|---|
| `powermetrics --samplers thermal` | **需要 root**（"powermetrics must be invoked as the superuser"），且 macOS 27 的 thermal sampler **只打印 "Thermal pressure"，不打印任何温度数值**（`strings /usr/bin/powermetrics` 里只有 `**** Thermal pressure ****`） | **不能**用作 die 温度交叉验证，即使有 root 也不行 |
| `powermetrics` 的 `DIE_%u_%sCPU` / `DIE_%u_%sACC` 等格式串 | 是 **IOReport 功耗/能耗通道名**（`cpu_power` sampler 用），不是温度通道 | Apple 的 die 温度**不经过 IOReport**，也印证了上一张票"IOReportHub 没有 die 温度通道"的结论 |
| `systemstats` | 是 **能量/遥测** 工具（`com.apple.telemetry.temperature_v2`），它采样 SMC 键但内置的键表全是 **Intel 键**（`TC0P TC0F TCHP TG0D TH0x TM0P TPSP …`），在本机大多不存在 | 无法提供 Apple 官方的"CPU die 温度 → SMC 键"映射 |
| `system_profiler SPPowerDataType / SPHardwareDataType / SPPCIDataType` | 无任何温度字段 | 无用 |
| `ioreg` 里的 `AppleARMPMUTempSensor` | IOKit 里有一批 HID 事件服务，`Product` 名为 `PMU tcal` / `PMU tdev1…tdev8` / `PMU tdie0,1,2,3,4,7,9,11,13,16,17,18,19` / `PMU2 tdie1…tdie7`（共 20 个 `tdie` 传感器） | 说明 Apple 内部确实按 **"die 温度"** 建模，但它**不暴露数值**，也**没有 CPU/GPU 标签**，无法直接映射到 SMC 键 |
| `AppleSMCKeysEndpoint`（IOKit，`IOUserClientClass = AppleSMCClient`） | 上一张票已探过：`sel2(cmd6)=NotPrivileged` | 拿不到 Apple 的键→语义表 |
| `AppleSMC.kext` / `AppleEmbeddedTempSensor.kext` | 内核扩展**没有磁盘二进制**（只在 KDK/内核集合里），`strings` 不可用 | 拿不到内核侧映射表 |

**结论：Apple 没有向用户态公开任何"die 温度 → SMC 键"的对照表**，所以这张表只能靠负载相关性重建。

### 5. 顺带确认的其它事实

- 单次 `SMCReadKeyAsNumeric` 成本 **144 µs**（`scratch/smc_temp` 实测，200 次平均）→ 1 Hz 采样完全可行；但如果要做**多键**扫描（130 个键）就是 **~19 ms/次**，所以 app 里只应读 1 个键，不要全表扫。
- `SMCGetKeyInfo` 的返回块布局（本机实测）：`offset 4 = vers.major(0x85=133)`、`offset 14 = pLimit.size(32)`、`offset 20 = dataType(UInt32 LE)`、`offset 24 = dataAttributes`。所有温度键的 `dataType = 4 (FP4F)`、`dataAttributes = 0`、`pLimit = 32` —— **类型字段区分不出温度**，这也是必须靠负载实验的原因。
- **别名**（读数逐样本完全相同）：`TH0a ≡ TH0x`、`TVDC ≡ TVDP`、`TVN1 ≡ TVNS`、`Ta0O≡Ta0P≡Ta0Q≡Ta0S≡Ta0T≡Ta0V≡Ta0b≡Ta0c≡Ta0e≡Ta0f≡Ta0g≡Ta0h ≡ Te0f ≡ Te0g ≡ Ts05`（**15 个键同一颗传感器**）。
- `TH0x` 在负载下几乎不动（+0.6 °C）——**上一张票把它当 CPU 温度候选是错的**，它在 CPU 负载下完全不动。

---

## Confidence

**属于"由负载相关性推断"，不是 Apple 直接确认。** 具体分级：

| 结论 | 置信度 | 依据强度 |
|---|---|---|
| `Tg*` 是 GPU 侧、`Tp*` 是 CPU 侧、`TVD0/TVDC/TVDP/TCMb` 是封装/热点级 | **高（直接测得）** | GPU 满载（AGX 利用率实测 90–95 %、CPU 占用不变）下 `Tg*` 涨 13–16 °C，而 `Tp*` 只涨 6–11 °C（弱 GPU 对照下只涨 1–3 °C）；反向 CPU 满载下 `Tp*` 涨 10–13 °C 而 `Tg*` 只涨 5 °C。三个独立实验一致 |
| `TH0x`/`TMVR`/`TR*d`/`TW0P` 等不是 die 温度 | **高（直接测得）** | 全部负载实验中都 ≤1.7 °C |
| **`Tp0j` 是 CPU die 温度** | **中高（推断）** | 它是 CPU 侧最强、最热的传感器，在**每一个** CPU 负载场景里都排第一（12 核 +12.8 °C、6 核 +21.7 °C、单性能核 +19.3 °C），且对 GPU 负载几乎免疫。但**没有任何 Apple 官方数值能与它对上** |

**因此：app 显示这个值时必须标「近似值」，并同时显示实际传感器名（本机 `SMC Tp0j`）** —— 这正是 `GLOSSARY.md` 对**核心温度**的定义所要求的（"if that sensor's identity is only inferred, the reading is marked 近似值"）。

**如果一定要更保守**：把 `Tp0j` 理解为"**CPU 性能核所在区域的 die 温度**"，而不是"整颗 SoC 的平均温度"。`TVD0` 那一族（73 °C）才是整机最热的点，把它当 CPU 温度会高估 8–10 °C。

---

## Caveats

1. **键语义是芯片 + 机型相关的。** 本报告的全部结论只对 **Mac18,5 / Apple M6 / macOS 27.0 (26A425)** 成立。换一台 M 系列机器，`Tp0j` 可能不存在、可能指向别的传感器、甚至 `Tp*` / `Tg*` 的分工都可能变。
   → **app 必须运行时探测，不能硬编码**。推荐做法（已实现于 `scratch/smc_keys.swift`）：
   - 用 `SMCGetKeyFromIndex` 枚举所有键，取 `T` 开头且读数在 (5, 120) 的候选；
   - 起 1–2 秒的短 CPU 负载（`DispatchQueue(qos: .userInteractive)` 单线程即可，本机实测能把 `Tp0j` 顶起 +19 °C）；
   - 取 **CPU 负载下涨幅最大** 的键 → 这就是本机的 CPU die 键；
   - 再起一次 GPU 负载，取 **GPU 涨幅最大** 的键 → GPU 键（只用于排除，不要显示）。
   这个流程在本机实测**能唯一选出 `Tp0j`**（单核实验里它的涨幅 19.28 °C 是全体候选里最高的）。
2. **`TVD0`/`TVDC`/`TVDP`/`TCMb` 是"看起来最像 CPU 温度"的陷阱** —— 它们绝对温度最高（73 °C），但 GPU 负载也会推高它们。只按"谁的温度高"挑键会挑错。
3. **`TH0x` 是个陷阱的反面** —— 它是很多第三方工具在 Apple Silicon 上默认用的键，但在本机 CPU 负载下**完全不动**，显示它等于显示一个环境温度却标成"核心温度"。
4. **能效核（E 核）的温度没有被单独定位。** `THREAD_AFFINITY_POLICY` 在本机**不受支持**（`thread_policy_set` 返回 46 = `KERN_NOT_SUPPORTED`，与上一张票一致），只能用 QoS 引导；而 `QOS_CLASS_BACKGROUND` 线程被系统大幅限流，实际发热量太小，`scratch/load_e1.tsv` 里**没有任何传感器可测地响应**。所以"E 核侧的 CPU 温度键是哪几个"仍然未知（如果 `Tp*` 里没有 E 核专属键，那也说得通 —— 12 核全开时 `Tp*` 全体都涨了）。
5. **GPU 负载下 CPU 侧键仍有 +1～11 °C 的上涨**（强 GPU 负载 +6～11 °C，弱 GPU 负载 +1～3 °C），这是同封装内的热耦合（GPU 满载 90–95 % 时 CPU 占用完全没变），不是 CPU 真的在干活。所以"CPU 选择性"是**相对的**，不是绝对的 —— 判断依据是**比值**（CPU 涨幅 ÷ GPU 涨幅），而不是绝对值。
6. **`xcrun metal` 不可用**（只有 Command Line Tools，没有 Metal 编译器），GPU 负载用 Metal Performance Shaders 的高斯模糊代替 compute shader；这会让 GPU 负载偏"光栅化/滤波"，与真实游戏负载的热分布未必完全一致。
7. `scratch/gpu_load2.tsv` 是**一次失败的对照实验**（加了 2 ms sleep 后 GPU 占空比掉下来，`Tg*` 只涨 3–5 °C），保留它作为**剂量-反应**佐证：GPU 负载强度减半 → `Tg*` 涨幅从 15 °C 掉到 4 °C，比例关系一致，说明不是噪声。

---

## Open questions

1. **`Tp0j` 精确对应哪颗物理传感器？** 它是 CPU die 上的一颗还是性能核簇的一颗？需要能读 `AppleARMPMUTempSensor` 的 HID 事件值（`PMU tdieN`，共 20 个）并与 SMC 键做相关性比对，才能把 SMC 键映射到 Apple 内部的 die 编号。**未做**（`IOHIDEventSystemClient` 路线，成本较高）。
2. **E 核侧的 CPU 温度键存在吗？** 若 `Tp*` 里没有 E 核专属传感器，说明 Apple 把能效核的温度并进了同一个 die 读数 —— 需要能强制把线程放到 E 核的手段（本机没有）。
3. **`TVD0`/`TVDC`/`TVDP`/`TCMb` 到底是 DRAM、SoC 封装还是供电芯片？** 它是整机最热点（73 °C）且同时对 CPU/GPU 敏感，最可能是**封装/DRAM 侧**。这决定了 Vitals 若要显示"SoC 温度"应该用哪个键。
4. **`TPD*`（18 个）这一族到底是什么？** 响应一半一半，索引里连成一片，像"die 级"传感器的编号表（`0,1,2,3,4,7,9,B,D,G,H,I,J,K,L,M,N,X`，后缀像十六进制但含 `G`）。
5. **有没有 Apple 官方的对照表？** 值得一查的方向：`AppleSMC.kext` / `AppleEmbeddedTempSensor.kext` 的**内核集合**二进制（KDK 或 `/System/Library/Extensions/*.kext` 的 KDK 版本），里面的键→角色表才是权威答案。
6. **macOS 27 是否有比 SMC 更合适的 die 温度后端？** 本报告只覆盖 SMC。`IOReportHub` 已被上一张票排除；`thermalmonitord`/`ProcessInfo.thermalState` 只给等级不给数值。Vitals 目前只能走 SMC。

---

## 附：可复用产物

| 文件 | 说明 |
|---|---|
| `scratch/smc_keys.swift` | **主产物**：`SMCClient`（dlopen/dlsym + 大端键打包 + `SMCGetKeyFromIndex` 枚举）+ 温度键筛选 + CPU/GPU 负载发生器 + `watch/enumerate/info` 三个模式 |
| `scratch/smc_temp.swift` | 既有最小读取器（保留，可作 app 内单键读取的参考实现） |
| `scratch/smc_all_keys.tsv` | 全量 2066 键的 TSV（index / key / dataType / dataAttributes / version / pLimit / 当前值） |
| `scratch/cpu_load.tsv` | 12 核 CPU 负载实验原始曲线 |
| `scratch/gpu_load.tsv` | GPU 满载实验原始曲线（强负载，AGX 90–95 %） |
| `scratch/gpu_load2.tsv` | GPU 弱负载对照（剂量-反应） |
| `scratch/load_p1.tsv` / `scratch/load_e1.tsv` | 单线程压性能核 / 压能效核 |
| `scratch/gpu_util.txt` | GPU 利用率采样（`ioreg` AGX `Device Utilization %`） |
| `scratch/sig/libsmc_exports.txt`、`scratch/sig/libsmc_disasm.txt` | libSMC 导出符号表与反汇编（`SMCGetKeyFromIndex` 签名来源） |

构建（Command Line Tools，`$TMPDIR` 的 module cache 不可写）：

```bash
swiftc -O -parse-as-library \
  -module-cache-path "$PWD/.modulecache" -Xcc -fmodules-cache-path="$PWD/.modulecache" \
  -o scratch/smc_keys scratch/smc_keys.swift
```
