# Vitals

A personal macOS monitor that shows the health of one machine — CPU load, CPU temperature, memory, power state — in a menu-bar readout and a floating panel.

## Language

### Measurements

**核心温度** (core temperature):
The CPU die's temperature in °C, read from a single primary temperature sensor chosen by a fixed priority order. The name of the sensor actually read is always shown alongside the value; if that sensor's identity is only inferred, the reading is marked 近似值.
_Avoid_: 处理器温度, CPU 温度, 芯片温度

**热压力等级** (thermal pressure level):
The operating system's own four-state verdict — nominal / fair / serious / critical — on whether the machine is thermally constrained. A level, never a number.
_Avoid_: 温度, 过热警告

**SoC 热点** (SoC hotspot):
The temperature of the System-on-Chip package itself — the hottest point on the board, and the one closest to the throttle boundary. It rises with CPU *and* GPU load, so it is never presented as the CPU's temperature.
_Avoid_: CPU 温度, 芯片温度, 封装温度

**近似值** (approximate reading):
A figure that is not a direct measurement of the quantity it names (e.g. a GPU load derived from a driver statistic rather than a true utilization). Always labelled as approximate in the interface.
_Avoid_: 估算值, 估值

**不可用** (unavailable):
A metric that cannot be read right now, with the reason known. Distinct from a metric that legitimately reads zero.
_Avoid_: 无数据, 空, 0, N/A

### CPU

**CPU 占用** (CPU load):
The share of CPU time not idle, as a percentage. Two flavours: the aggregate across all cores, and per-core.
_Avoid_: CPU 使用率, CPU 百分比

**核型** (core type):
One of three kinds of core in this machine's CPU — 超频核 (Super), 性能核 (Performance), 能效核 (Efficiency) — which determines how a loaded core is actually costing you.
_Avoid_: 大核, 小核, 核心类型

**已用内存** (memory used):
The physical memory currently in use: (active + inactive − purgeable) + wired + compressed, i.e. the same figure `top` prints as `PhysMem: used`. It **includes** file-backed pages, so it is larger than the Activity Monitor's "Memory Used".
_Avoid_: App 内存, 活动监视器内存, 内存占用

**采样间隔** (sampling interval):
How often the collectors ask the system for a fresh reading. One second throughout.
_Avoid_: 刷新率, 轮询周期

**滚动窗口** (rolling window):
The span of recent samples the on-screen curves cover — 60 seconds.
_Avoid_: 图表范围, 时间跨度

### Backend and trust

**后端** (backend):
One particular way of obtaining a metric from the system (a public API, a private API, or the privileged helper). Exactly one backend serves each metric at a time.
_Avoid_: 数据源, 采集方式

**降级链** (fallback chain):
The ordered sequence of backends tried when the preferred one is unavailable, ending in the metric being shown as 不可用. A metric never falls back to a fabricated number.
_Avoid_: 备用方案, 容错

**惰性探测** (lazy probing):
Identifying which sensor to read only when the known one stops working — instead of probing on every launch. The result is cached on disk together with the machine and OS version.
_Avoid_: 自动检测, 智能识别

**窗口分档** (window level):
Which set of blocks the floating panel shows, decided by its size: L0 is a single text line, L5 shows everything. Too short a window drops to a lower level rather than clipping content.
_Avoid_: 响应式断点, 布局模式
