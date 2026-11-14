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
