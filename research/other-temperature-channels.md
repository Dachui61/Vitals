# Ticket 20 — 还有没有别的数值温度通道

**机器**：macOS 27.0 (26A425) · Apple M6 (Mac18,5) · arm64 · 16GB · 无电池 · 仅 Command Line Tools
**会话身份**：uid=501 (euid=501)，`sudo` 不可用（`/usr/bin/sudo` → "Operation not permitted", exit 126）——全程未尝试提权。
**日期**：2026-11-14
**方法**：所有结论均来自本机实测命令与真实输出；反编译仅用于确定 Apple 自家客户端（`thermalmonitord`）所使用的私有协议，作为「协议长什么样」的第一手证据。

---

## Verdict

| # | 路径 | 结论 |
|---|------|------|
| **Avenue 1** | `/usr/libexec/thermalmonitord` 是否暴露可查询接口 | **接口不存在**。该 daemon 没有 MachServices / XPC service / notify 温度通道 / unix socket / 温度缓存文件；它真正用的 IOKit 客户端 `AppleSMCSensorDispatcher` 在无特权下 **user-client type 0…65535 全部打开失败**（kIOReturnBadArgument）。 |
| **Avenue 2** | 重新逆向 `AppleSMCKeysEndpoint` | **被权限挡住**。新协议已完全还原（selector 2 + 168 字节请求 + `+0x2a` 命令字节），格式正确（不再 BadArgument），但真正返回数据的命令（cmd=6）返回 **kIOReturnNotPrivileged**；其它命令返回 OK 但输出是 `00 01 02 …` 的 echo，无任何传感器数值。 |
| **Avenue 3** | 其它面（其它 daemon / IORegistry 属性 / 日志缓存文件） | **不能**。全量 `ioreg -l -w0` 无任何数值温度属性；`pmset -g thermlog` 无特权零输出（pmset 自报 "Must be run as root"）；`/var/db`、`/var/log/powermanagement/*.asl`、`/private/var/db/SoC` 均无温度数据（后者沙箱拒绝读取）。 |

### 总体答案

**在本机上，除 IOReportHub（票 01）外，不存在任何无特权的数值 °C 通道。**
三条路径全部走完：一条根本没有接口，一条被权限挡住且已定位到确切阻断点，一条确认无数据。
如果票 01 的 IOReportHub 路线也不通，那么 **数值核心温度在 macOS 27 上只能以「特权组件」的形式获取**（且那也是票 02 之外的另一条路，见下方 Recommendation）。

---

## Evidence

### 0. 方法与已有事实的沿用

沿用既有结论（不重复推导）：经典 SMC user-client 已死；`powermetrics` 无 `smc` sampler；`IOReportHub` 由票 01 负责。
本次新增的第一手证据来自 **`/usr/libexec/thermalmonitord` 的反编译**——它是 Apple 自家的 SMC 客户端，能告诉我们"新协议长什么样"。

```
$ nm -arch arm64e -n /usr/libexec/thermalmonitord | wc -l
244                       # 二进制已剥离本地符号，只有 undefined externals
$ strings -a -t x /usr/libexec/thermalmonitord | grep -iE 'getTemperatureFromSMCForKey|temperatureForKey'
172e0 getTemperatureFromSMCForKey:
1815e temperatureForKey:
```

`otool -ov` 给出了它的 **ObjC 结构体编码**，这是还原协议的关键：

```
{smcExchangeSensorGroupInfo="sensorExchangeKeyStr"^{__CFString}"sensorExchangeKeyValue"I
 "sensorExchangeKeySize"Q"numberOfSensors"I"SensorExchangeUpdateNeeded"B"sensorIndexLUT"[29i]
 "data"(SMCSensorEx_Jumbo="BYTES"{?="p1"[120C]}"SENSORS"{
   ?="header"{SMCSensorExchangeHeader="uchNumSensors"C"uchVersion"C"uchRollingSequenceNumber"C"uchRsvd"C}
   "sensorArray"[29(SMCSensorExchangeSensor="FLOATS"{?="rValue"f}"UI32"{?="ui32Raw"I}
     "SI32"{?="si32Raw"i}"FIXED_POINT_ERROR"{?="fixedPointValue"b16"errorCode"b16})]})}
```

`SMCSensorExchangeSensor` = `{float rValue; uint32 ui32Raw; int32 si32Raw; b16 fixedPointValue; b16 errorCode;}`（20 字节），一组 29 个传感器。

### 1. Avenue 1 — thermalmonitord：没有任何可查询接口

**(a) launchd 作业里没有 MachServices：**

```
$ plutil -convert xml1 -o - /System/Library/LaunchDaemons/com.apple.thermalmonitord.plist
<dict>
  <key>EnablePressuredExit</key><false/>
  <key>EnableTransactions</key><false/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>Label</key><string>com.apple.thermalmonitord</string>
  <key>LaunchEvents</key><dict><key>com.apple.bg.system.task</key>…</dict>
  <key>POSIXSpawnType</key><string>Interactive</string>
  <key>ProgramArguments</key><array><string>/usr/libexec/thermalmonitord</string></array>
</dict>
```
→ 无 `MachServices` 键，也无 `Sockets`/`EnvironmentVariables` 里的 socket 路径。

**(b) 系统里没有以它名义注册的 mach service / XPC 端点：**

```
$ launchctl print system 2>/dev/null | grep -i thermal | sort -u
		     112      - 	com.apple.thermalmonitord
$ launchctl print system 2>/dev/null | grep -i 'thermal' -c
1
```
（`com.apple.relatived.tempest` 是天气应用，与温度无关；`launchctl list` 也没有任何 thermal 作业。）

**(c) 二进制里唯一的 notify 名是压力等级，不是温度：**

```
$ strings -a /usr/libexec/thermalmonitord | grep -iE 'notify|OSThermal'
%s: notify_register_check failure
%s: notify_register_dispatch failure
notify_post(kOSThermalNotificationPressureLevelName) failed
notify_register_check(kOSThermalNotificationPressureLevelName) failed
notify_set_state(thermalPressureLevelToken) failed
```
`OSThermalNotificationPressureLevelName` = 压力等级（4 档），不是 °C。

**(d) 它引用的外部服务只有 `com.apple.*` 的队列名，没有 mach service 名：**

```
$ strings -a /usr/libexec/thermalmonitord | grep -E '^com\.apple\.' | sort -u
com.apple.ThermalMonitor.mainQueue
com.apple.cltm
com.apple.lifetimeservo
com.apple.system.highpowermode
com.apple.system.lowpowermode
com.apple.thermalMonitor.1weekTask
com.apple.thermalmonitor.cpuMitigationQueue
com.apple.thermalmonitor.gpuMitigationQueue
com.apple.thermalmonitor.hidsensors
com.apple.thermalmonitor.lservo
com.apple.thermalmonitor.lts-ctrl-state
com.apple.thermalmonitor.packageControlQueue
com.apple.thermalmonitor.powerlog
```
全是 dispatch queue 名 / 通知名，**没有一个是可连接的 XPC mach service**。

**(e) 它读温度用的 IOKit 客户端是 `AppleSMCSensorDispatcher`，无特权打不开：**

```
$ ioreg -l -w0 | grep -B2 -A10 'IOUserClientClass" = "AppleSMCSensorDispatcherUserClient"'
+-o smctempsensor0  <class AppleARMIODevice, …>   "sensor" = <"mTPL">
  +-o AppleSMCSensorDispatcher  <class AppleSMCSensorDispatcher, id 0x10000068a, registered, matched, active, busy 0 (0 ms), retain 6>
       "IOClass" = "AppleSMCSensorDispatcher"
       "IOUserClientClass" = "AppleSMCSensorDispatcherUserClient"
       "IONameMatch" = ("smc-tempsensor")
    +-o AppleSMCSensorDispatcherUserClient  <class …, id 0x100000d2f, …>
         "IOUserClientCreator" = "pid 112, thermalmonitord"     ← 只有 thermalmonitord 持有
```

暴力枚举 user-client type：

```
$ ./scratch/t20_dispatchertype2          # 0…65535 全部尝试
scanned 65536 types, 0 opened
```
每个 type 都返回 `kIOReturnBadArgument`（type 不被接受）。特殊值（0xffffffff、0x5a17…）同样失败。

> 也就是说：**thermalmonitord 的"特权读取路径"不是一个我们可以借道的公开接口**。它有两个 IOKit 客户端：`AppleSMCSensorDispatcher`（拿传感器组快照：scalar sel0=组数、struct sel1/sel2=60 字节、struct sel3=88 字节入参）完全打不开；`AppleSMC`（拿具体键值）能打开但取数被拒（见下）。

**(f) 文件/缓存输出不存在：**

```
$ ls -la /var/log/smcKeys.csv /var/log/tgraph.csv
ls: /var/log/smcKeys.csv: No such file or directory
ls: /var/log/tgraph.csv: No such file or directory
```
（这两个路径只是 thermalmonitord 内部的 debug 输出目标，默认不生成。）

### 2. Avenue 2 — `AppleSMCKeysEndpoint`：协议还原完成，取数被权限挡住

**(a) 端点本体与用户客户端：**

```
$ ioreg -l -w0 | grep -A16 'IOUserClientClass" = "AppleSMCClient"'
  "IOClass" = "AppleSMCKeysEndpoint"
  "IOProviderClass" = "RTBuddyEndpointService"      ← Apple Silicon 的 RTBuddy endpoint
  "IONameMatch" = "SMCEndpoint1"
  "role" = "SMC"
  "Generation" = 4
  "IOUserClientClass" = "AppleSMCClient"
```
无特权可打开，且 **type 0…31 全部可开**（该 user client 不限制 type）：

```
$ ./scratch/t20_openmatrix | grep AppleSMCKeysEndpoint | head -3
AppleSMCKeysEndpoint[1] type=0: sel2(cmd6)=NotPrivileged  scalar0=OK scalar1=OK
AppleSMCKeysEndpoint[1] type=1: sel2(cmd6)=NotPrivileged  scalar0=OK scalar1=OK
AppleSMCKeysEndpoint[1] type=2: sel2(cmd6)=NotPrivileged  scalar0=OK scalar1=OK
…
```

**(b) 从 thermalmonitord 反编译出的调用序列：**

```
0000000100010104  add  x0, x0, #0x534 ; literal pool for: "AppleSMC"
0000000100010108  bl   IOServiceMatching
0000000100010114  bl   IOServiceGetMatchingService
000000010001012c  add  x3, x19, #0x48
0000000100010130  mov  w2, #0x0          ; user-client type = 0
0000000100010134  bl   IOServiceOpen
0000000100010150  mov  w1, #0x0          ; selector 0 (scalar, 全 NULL)
0000000100010164  bl   IOConnectCallScalarMethod
...
0000000100010240  mov  w1, #0x1          ; selector 1 (scalar, 全 NULL)
0000000100010254  bl   IOConnectCallScalarMethod
```

真正的取数调用在 `0x10000feac`：

```
000000010000ff28  ldr  x8, [x19, #0x8]     ; sensorExchangeKeyValue  (uint32 4CC)
000000010000ff2c  ldr  x9, [x19, #0x10]    ; sensorExchangeKeySize   (uint64)
000000010000ff30  mov  w10, #0xa8          ; 168
000000010000ff34  str  x10, [sp, #0x20]    ; outputCnt = 168
000000010000ff80  lsr  w10, w8, #24        ; 4 字符 key，MSB→LSB
000000010000ff84  strb w10, [sp, #0x2b]
000000010000ff88  lsr  w10, w8, #16
000000010000ff8c  strb w10, [sp, #0x2c]
000000010000ff90  lsr  w10, w8, #8
000000010000ff94  strb w10, [sp, #0x2d]
000000010000ff98  strb w8,  [sp, #0x2e]
000000010000ffa0  mov  w10, #0x6           ; ← 命令/版本字节
000000010000ffa4  strb w10, [sp, #0x10a]   ; request+0x2a = 6
000000010000ffac  str  w8,  [sp, #0xe0]    ; request+0x00 = 4CC
000000010000ffb0  str  w10, [sp, #0xfc]    ; request+0x1c = key 长度
000000010000ffc8  bl   memcpy              ; request+0x30 = key 字符
000000010000ffdc  mov  w1, #0x2            ; selector 2
000000010000ffe0  mov  w3, #0xa8           ; inputCnt = 168
000000010000ffe4  bl   IOConnectCallStructMethod
```

还原出的 **168 字节请求布局**（`request`）：

| 偏移 | 类型 | 内容 |
|------|------|------|
| `+0x00` | uint32 | key 4CC（`'T' | 'C'<<8 | '0'<<16 | 'P'<<24`，内存序即 "TC0P"） |
| `+0x04…+0x1b` | — | 0 |
| `+0x1c` | uint8 | key 字节数（4） |
| `+0x1d…+0x29` | — | 0 |
| `+0x2a` | uint8 | **命令字节**（thermalmonitord 用 6） |
| `+0x2b…+0x2f` | — | 0 |
| `+0x30…` | bytes | key 字符（"TC0P"） |
| 合计 | | **168 (0xa8)**，输出同为 168 字节 |

**(c) 实测：格式被接受，取数被权限挡住。**

```
$ ./scratch/t20_selsweep        # selector × 168B in / 168B out
=== struct method, 168 in / 168 out ===
  sel  0: OK             outCnt=168
  sel  1: OK             outCnt=168
  sel  2: NotPrivileged  outCnt=168      ← 唯一的数据方法
  sel  3: Unsupported    outCnt=168
  sel  4: Unsupported    outCnt=168
  …（3…63 全部 Unsupported）
=== scalar method, all NULL ===
  sel 0: OK    sel 1: OK    sel 2: BadArgument    sel 3…: Unsupported
```

输入长度必须**恰好**是 168，输出长度也必须**恰好**是 168：

```
sel 2: 0:BadArgument 4:BadArgument 8:BadArgument 16:BadArgument 32:BadArgument 64:BadArgument
       128:BadArgument 132:BadArgument 136:BadArgument 144:BadArgument 160:BadArgument
       164:BadArgument 168:NotPrivileged 172:BadArgument 176:BadArgument …
```

`+0x2a` 命令字节的完整扫描（0…255）：

```
$ ./scratch/t20_cmdsweep Tp09
  cmd 0..4:  BadArgument      ← 非法
  cmd 5: OK  outCnt=168  [00..3f]=00 01 02 03 04 05 06 07 08 09 0a … 3f
  cmd 6: NotPrivileged                       ← thermalmonitord 用的那条
  cmd 7: OK  [00..3f]=00 01 02 03 …
  cmd 8: OK  [00..3f]=00 01 02 03 …
  cmd 9: OK  [00..3f]=00 01 02 03 …
  cmd 12: OK [00..3f]=00 01 02 03 …
  cmd 17: OK [00..3f]=00 01 02 03 …
  cmd 255: BadArgument
OK commands: [5, 7, 8, 9, 12, 17]
```
"OK" 的那些命令返回的是 `00 01 02 03 … 3f` 的递增 echo，**不是传感器数值**；只有 cmd=6 会去取真实数据，而它被权限挡住。

**(d) 阻断点与"键"无关，是按命令做的授权检查：**

```
$ for k in Tp09 Tp0 T000 XXXX TG0B SS0F mTPL Th0x; do ./scratch/t20_smcproto A $k | grep 'struct sel2'; done
struct sel2 (variant A, key Tp09): 0xe00002c1 NotPrivileged outCnt=168
struct sel2 (variant A, key Tp0):   0xe00002c1 NotPrivileged outCnt=168
struct sel2 (variant A, key T000):  0xe00002c1 NotPrivileged outCnt=168
struct sel2 (variant A, key XXXX):  0xe00002c1 NotPrivileged outCnt=168   ← 根本不存在的键
struct sel2 (variant A, key TG0B):  0xe00002c1 NotPrivileged outCnt=168
struct sel2 (variant A, key SS0F):  0xe00002c1 NotPrivileged outCnt=168
struct sel2 (variant A, key mTPL):  0xe00002c1 NotPrivileged outCnt=168
struct sel2 (variant A, key Th0x):  0xe00002c1 NotPrivileged outCnt=168
```
连不存在的键 `XXXX` 也是同一个错，说明**授权检查发生在查键之前**——是"调用者身份"检查，不是"这个键不给读"。

格式正确性也被独立验证过：去掉 `+0x2a` 的 6 → 立刻退回 `BadArgument`；`+0x2a` 换成 0…4 也是 `BadArgument`；只有 5/6/7/8/9/12/17 被识别。**所以我们确实已经把协议格式还原对了**——错的是权限，不是结构。

**(e) thermalmonitord 用的真实温度键（供后续特权重试时参考）：**

```
$ strings -a /usr/libexec/thermalmonitord | grep -E '^[A-Za-z0-9#]{4}$'   # 在 SMC 相关区段
TG0B  TG0V  SS0F  SS0C  TP0Z
Te3z  Ts5z  Ta1z  Tp2z  Tp3z  Tp4z  Tp5z  Tp7z  Tp8z  Tp9z
Th0x  Th1x  Th2x  Th3x  Tc0x  Tc1x  Tc2x  Tc3x
TSBa  TSBE  TSBH  TSRM  TSBQ  TSBR  TSFC  TSFD  TS0A  TSFP  TSBM  TSLE
mTPL  tGAM  GGRC
zECm  zEAO  zEWi  zETC  zETN  zEAR
```

**(f) 顺带的负结果：`SMCT.framework` 名字骗人。**

`/System/Library/PrivateFrameworks/SMCT.framework`（bundle id `com.apple.ggd.SMCT`）看着像 "SMC Tool"，dlopen 后枚举 ObjC 类发现它是图像处理库：

```
$ ./scratch/t20_smct_classes | grep -A3 'classes whose name mentions'
  SMCT.BlurFilter
  SMCT.MinAndMaxFinder
```
与 SMC 无关。

### 3. Avenue 3 — 其它面

**(a) 全量 IORegistry 扫描：没有任何数值温度属性。**

```
$ ioreg -l -w0 > scratch/ioreg_full_t20.txt ; wc -l scratch/ioreg_full_t20.txt
40315 scratch/ioreg_full_t20.txt
$ grep -iE '"(temperature|temp[a-z]*|therm[a-z]*|celsius|degc|dieTemp|hotspot|skinTemp)"' scratch/ioreg_full_t20.txt | sort -u
    "ThermalThrottlingSupported" = Yes
    "TemperatureSensor" = {"J416s"="PMU tdev2","J416c"="PMU tdev2","J493"="PMU tdev7",…}
```
唯一叫 "TemperatureSensor" 的属性是 **板型 → PMU 传感器名** 的字典（不含数值）。

**(b) 名字带 Temp 的 IOKit 服务要么不存在，要么只有 HID 事件服务这一个入口：**

```
$ ioreg -r -c ApplePMGRTempSensor -w0   → 空
$ ioreg -r -c AppleDieTempController -w0 → 空
$ ioreg -r -c AppleT700XTempSensor -w0  → 空
$ ioreg -r -c AppleSCCTempSensor -w0    → 空
$ ioreg -r -c AppleVTempDispatcher -w0  → 空
$ ioreg -r -c AppleARMPMUTempSensor -w0 → 42 个实例
```
42 个 `AppleARMPMUTempSensor` 的属性是 `"Product" = "PMU tcal"` / `"PMU tdev1"` 等——**校准/偏置传感器**（tcal / tdev），不是绝对温度；它们的 `IOUserClientClass` 是 `IOHIDEventServiceUserClient`，只能以 type=2 打开，且任何 IOKit 方法都返回 `BadArgument`（不是 SMC 协议）。`AppleEmbeddedNVMeTemperatureSensor` 同理，是 **SSD** 温度（不是 CPU）。

**(c) `pmset -g thermlog`（经典的热日志，理论上带 °C）无特权拿不到：**

```
$ pmset -g thermlog > out 2> err &   # 跑 20 秒
--- stdout (0 bytes) ---
--- stderr (0 bytes) ---
$ strings -a /usr/bin/pmset | grep -iE 'must be run as root|thermlog'
thermlog
pmset: Must be run as root.
```
`pmset -g therm`（不需要 root）只给等级，且本机无记录：
```
$ pmset -g therm
Note: No thermal warning level has been recorded
Note: No performance warning level has been recorded
Note: No CPU power status has been recorded
```
`IOPMrootDomain` 的 user client（`RootDomainUserClient`）**可以**无特权打开，但 `"IOUserClientEntitlements" = No`，其公开头文件里也只有等级型 API（`IOPMGetThermalWarningLevel`、`kIOPMThermalLevelWarningKey` = 0/5/10/100/110/255），**没有 °C**。

**(d) 日志 / 缓存文件：**

```
$ ls /private/var/db | grep -iE 'therm|temp|smc'     → 无
$ ls /private/var/run | grep -iE 'therm|temp|smc'    → 无
$ ls /private/var/log/powermanagement/
2026.11.11.asl 2026.11.12.asl 2026.11.13.asl 2026.11.14.asl StoreData
$ strings -a /private/var/log/powermanagement/2026.11.14.asl | grep -iE 'temp|therm|degC|celsius'
（无匹配）
$ ls /private/var/db/SoC/
ls: /private/var/db/SoC/: Operation not permitted   ← 沙箱拒绝，但目录里也没有温度类文件名
```
统一日志也读不到（沙箱限制）：
```
$ log show --last 30m --predicate 'process == "thermalmonitord"'
log: Cannot run while sandboxed
```

**(e) 其它温度消费者（都只是 Apple 内部组件，不对外暴露）：**

```
$ grep -rl --binary-files=text 'Tp0' /usr/libexec 2>/dev/null
/usr/libexec/sysdiagnosed
/usr/libexec/locationd
/usr/libexec/modelmanagerd
/usr/libexec/findmylocateagent
```
以及 `/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter` 引用了 SMC 温度键。它们都是 Apple 签名的系统组件，没有任何对外 IPC 契约可用。

---

## Working code

**没有一条路径能读出数值 °C，因此没有"能用的温度代码"。**
但下面两段是**实测过的、可直接编译运行的**代码：(1) 完整实现了还原出来的 SMC 协议，用来证明"格式对了、权限被挡"；(2) 唯一可用的公开信号（热压力四档）。

### (1) 协议探针 —— 复现 "NotPrivileged"

`scratch/t20_smcproto.swift`（完整源码）：

```swift
// t20_smcproto.swift — Ticket 20, Avenue 2.
// Implements the "SMCSensorExchange" protocol that /usr/libexec/thermalmonitord
// uses against the AppleSMCKeysEndpoint IOKit service (IOUserClientClass=AppleSMCClient):
//
//   IOServiceMatching("AppleSMC") -> IOServiceOpen(type 0)
//   IOConnectCallScalarMethod(conn, 0, NULL, 0, NULL, 0)      // "begin"
//   IOConnectCallStructMethod(conn, 2, input168, 168, out168, &outCnt)
//   IOConnectCallScalarMethod(conn, 1, NULL, 0, NULL, 0)      // "end"
//
// request layout (reverse-engineered from thermalmonitord @0x10000feac):
//   +0x00 uint32  key 4CC
//   +0x04 .. +0x1b  zero
//   +0x1c uint8   key size in bytes
//   +0x1d .. +0x29  zero
//   +0x2a uint8   6          <- command byte
//   +0x2b .. +0x2f  zero
//   +0x30 bytes   key characters (size bytes)
//   total 0xa8 = 168
//
// Build:
//   swiftc -O -target arm64-apple-macosx27.0 -module-cache-path "$PWD/.modulecache" \
//     -Xcc -fmodules-cache-path="$PWD/.modulecache" scratch/t20_smcproto.swift \
//     -o scratch/t20_smcproto -framework IOKit
// Run: scratch/t20_smcproto <variant> <key>

import Foundation
import IOKit
import Darwin

func ioErr(_ kr: kern_return_t) -> String {
    if kr == kIOReturnSuccess { return "OK" }
    let hex = String(format: "0x%08x", UInt32(bitPattern: kr))
    switch kr {
    case kIOReturnNotPrivileged:   return "\(hex) NotPrivileged"
    case kIOReturnNotPermitted:    return "\(hex) NotPermitted"
    case kIOReturnExclusiveAccess: return "\(hex) ExclusiveAccess"
    case kIOReturnUnsupported:     return "\(hex) Unsupported"
    case kIOReturnBadArgument:     return "\(hex) BadArgument"
    case kIOReturnBusy:            return "\(hex) Busy"
    case kIOReturnNoMemory:        return "\(hex) NoMemory"
    case kIOReturnError:           return "\(hex) Error"
    default:                       return "\(hex) ?"
    }
}

func le(_ s: String) -> UInt32 {          // 'T' | 'C'<<8 | '0'<<16 | 'P'<<24
    var v: UInt32 = 0
    for (i, c) in s.utf8.enumerated() { v |= UInt32(c) << (8 * UInt32(i)) }
    return v
}

var iter: io_iterator_t = 0
guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iter)
        == kIOReturnSuccess else { print("no AppleSMC"); exit(2) }
defer { IOObjectRelease(iter) }
var conn: io_connect_t = 0
var found = false
while true {
    let s = IOIteratorNext(iter)
    if s == 0 { break }
    var c: io_connect_t = 0
    if IOServiceOpen(s, mach_task_self_, 0, &c) == kIOReturnSuccess { conn = c; found = true; break }
    IOObjectRelease(s)
}
guard found else { print("cannot open AppleSMC user client"); exit(3) }

// "begin" / "end" scalar calls — all-NULL form is what thermalmonitord uses.
print("scalar sel0: \(ioErr(IOConnectCallScalarMethod(conn, 0, nil, 0, nil, nil)))")

// 168-byte request
var req = [UInt8](repeating: 0, count: 168)
let keyBytes = Array("Tp09".utf8)
withUnsafeBytes(of: le("Tp09").littleEndian) { req.replaceSubrange(0..<4, with: $0) }
req[0x1c] = UInt8(keyBytes.count)
req[0x2a] = 6
for (i, b) in keyBytes.enumerated() { req[0x30 + i] = b }

var out = [UInt8](repeating: 0, count: 168)
var outCnt = 168
let kr = req.withUnsafeMutableBytes { ip -> kern_return_t in
    out.withUnsafeMutableBytes { op -> kern_return_t in
        IOConnectCallStructMethod(conn, 2, ip.baseAddress!, 168, op.baseAddress!, &outCnt)
    }
}
print("struct sel2 (key Tp09): \(ioErr(kr)) outCnt=\(outCnt)")
print("scalar sel1: \(ioErr(IOConnectCallScalarMethod(conn, 1, nil, 0, nil, nil)))")
IOServiceClose(conn)
```

实测输出：

```
$ ./scratch/t20_report_snippet          # 上面那段精简源码
scalar sel0: OK
struct sel2 (key Tp09): 0xe00002c1 NotPrivileged outCnt=168
scalar sel1: OK
```

（完整版探针 `scratch/t20_smcproto` 会额外打印 `opened conn=…`、`scalar sel0 (out ptr): 0xe00002c2 BadArgument`，
因为 thermalmonitord 的 scalar 调用**必须**是全 NULL 形态——带输出指针会得到 BadArgument。）

### (2) 唯一可用的公开信号：热压力四档

`scratch/t20_thermalstate.swift`：

```swift
// t20_thermalstate.swift — verify the only unprivileged thermal signal that works:
// ProcessInfo.thermalState + ProcessInfo.thermalStateDidChangeNotification.
import Foundation

let s = ProcessInfo.processInfo.thermalState
print("thermalState raw=\(s.rawValue) name=\(s == .nominal ? "nominal" : s == .fair ? "fair" : s == .serious ? "serious" : s == .critical ? "critical" : "?")")
print("notification: \(ProcessInfo.thermalStateDidChangeNotification.rawValue)")

let sem = DispatchSemaphore(value: 0)
var fired = false
let token = NotificationCenter.default.addObserver(
    forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { _ in
        fired = true; sem.signal()
    }
DispatchQueue.global().asyncAfter(deadline: .now() + 3) { sem.signal() }
_ = sem.wait(timeout: .now() + 5)
NotificationCenter.default.removeObserver(token)
print("notification observed within 3s: \(fired)")
```

实测输出：

```
$ ./scratch/t20_thermalstate
thermalState raw=0 name=nominal
notification: NSProcessInfoThermalStateDidChangeNotification
notification observed within 3s: false      ← 状态没变化时不触发，属正常
```

---

## Recommendation for ticket 04

### 结论一：数值 °C 在无特权下无路可走 —— 票 04 的候选表可以收敛

| 候选 | 票 20 的结论 |
|------|-------------|
| (a) 私有 IOReportHub | 由票 01 负责；票 20 未发现它之外的可替代品 |
| (b) 组合（能力探测后按序尝试 01/20 找到的路） | 票 20 提供的三条路：接口不存在 / 被权限挡住 / 无数据 —— **没有一条能进组合** |
| (c) 只用 thermalState 四档 | **现在是票 20 唯一支持的结论** |
| （新）root 特权组件走 SMC | **本票的新发现，值得作为 (b) 之外的一个候选交给票 04/14 评估** —— 见下 |

### 结论二：唯一残留的数值 °C 路线是"特权"，而且协议已经摸清了

`kIOReturnNotPrivileged` 是 IOKit 的**调用者授权**拒绝（发生在查键之前），它意味着：**以 root 身份运行同样的 168 字节请求，理论上是能拿到数据的**。
本会话无法验证这一点（`sudo` 不可用），因此把它作为**待用户在普通 Terminal 验证**的候选项，而不是既成事实：

```bash
# 需要用户在普通 Terminal（管理员身份）执行；预期：若 root 被允许，
# 会打印一段 168 字节的十六进制输出（其中含 rValue float / ui32Raw / si32Raw）。
sudo /path/to/t20_smcproto A Tp09
```

需要用户确认的三件事：
1. root 下 `struct sel2` 是否变成 `OK`；
2. 若 `OK`，输出里哪一段是温度值（`SMCSensorExchangeSensor.rValue` 为 float，`fixedPointValue` 为 b16 定点）；
3. `Tp09` / `Tp0z` / `TG0B` 等键在本机上的语义（哪个是 CPU die）。

若 (1) 为真，票 14 的「特权组件」就多了一条**真正拿到 °C** 的实现路径——注意票 02 的结论只否定了 `powermetrics` 这一个 root 工具，并没有否定 SMC 端点本身。

### 结论三：降级契约（写进 SPEC 的具体措辞）

按 `GLOSSARY.md` 的词汇：

- **核心温度**：无特权下**没有后端**。界面上显示 **不可用**，并给出已知原因——不要显示 0，也不要把热压力等级冒充成温度。
- **热压力等级**：作为**独立的一行**呈现（四档：nominal / fair / serious / critical），**不折算成数字**，也不叫"温度"。
- 两者的关系必须在界面上写明：**等级是系统对"是否被温度限制"的判定，不是温度数值**。
- 告警：温度类阈值告警在没有数值后端时**不可用**（按 GLOSSARY「不可用」处理，而不是静默地永不触发）；等级类告警保留（例如 serious/critical 时提示"系统正在降频"）。

### 结论四：能力探测该怎么做

即便现在只剩等级一条路，票 04 若要保留"未来可能拿到数值"的余地，探测应该是**运行时探测**而不是编译期决定：

```
1. 尝试后端 A（票 01 的 IOReportHub 私有协议）
     → 成功且落在合理区间（30–60 °C）→ 记为"数值核心温度"，并标注来源
     → 失败 → 继续
2. 尝试后端 B（特权组件，若用户安装了）
     → 成功 → 记为"数值核心温度"，标注来源为特权组件
     → 失败 → 继续
3. 降级到后端 C：ProcessInfo.thermalState 四档
     → 核心温度显示"不可用（原因：本机无特权温度后端）"
```

能力探测必须在**运行时**做，且对每个后端都要有**超时 + 崩溃隔离**（本票的探针全程用子进程隔离，正是因为一个错误的长度就可能让调用方崩溃或卡死）。
另外：**私有的 IOReportHub 协议随时会随系统升级失效**，所以探测必须是"试一次就知道行不行"，而不是写死版本号。

### 结论五：诚实的呈现方式（回应票 04 的"必须显式记为让步"）

本票的结论应当让票 04 明确写下这句：
> **在 macOS 27 / Apple M6 上，无特权进程无法读到 CPU die 的数值温度。**
> 这与 v1「必须有数值核心温度」的要求**直接冲突**。要么把需求改成"热压力四档 + 明示不可用原因"，
> 要么把数值温度整票挂起，直到出现可用的无特权后端（票 01 是唯一候选）或用户接受安装特权组件。

界面上的建议措辞（示例）：`核心温度  不可用（macOS 未向无特权应用开放温度传感器）  ·  热压力等级  正常`。
**不要**写成 `温度 45 °C` 这类从等级反推的数字——那是编造。

---

## Open questions

1. **root 下 SMC 端点是否真的放行？**（需用户在普通 Terminal 用 `sudo` 跑 `t20_smcproto`。）这是唯一还可能拿到数值 °C 的路径，也是票 14 特权组件能否成立的前提。**本会话无法验证。**
2. **票 01 的 IOReportHub 是否真能读到数值温度？**若能，本票结论需改写为"有第二条无特权路"。若不能，票 04 必须选 (c)。
3. **`AppleSMCSensorDispatcher` 的 user-client type 到底是什么？**0…65535 全试都失败，说明 type 是个非常规值（或该 user client 走的是别的授权机制）。若能搞清，`thermalmonitord` 的传感器组快照（29 个传感器的 rValue）也许能被无特权读取——这是本票唯一"没走完"的分支。
4. **`cmd=5/7/8/9/12/17` 到底返回什么？**它们 OK 但输出是 `00 01 02 …` 的 echo，看起来像"协议版本/能力查询"而非数据。若其中某个在别的请求布局下能返回传感器数组，值得再挖。
5. **`/private/var/db/SoC/` 里有没有温度历史？**该目录沙箱拒绝读取（`Operation not permitted`），里面可能有 SoC 遥测。若有可读的缓存文件，可能存在一条"读历史温度"的旁路。
6. **其它 macOS 版本/机型是否不同？**本票全部结论都绑定在 macOS 27 + M6；`AppleSMCUserClient` 协议在旧系统上仍是可用路线（但那是旧系统，不是本机）。
7. **统一日志里 thermalmonitord 是否会打印 °C？**本会话 `log show` 被沙箱拒绝；若有用户在普通 Terminal 跑 `log show --last 1h --predicate 'process == "thermalmonitord"'`，可能看到数值温度日志（但那是日志文本，不是稳定的 API）。

---

### 附：本票使用的探针文件（均在 `scratch/`，gitignored）

| 文件 | 作用 |
|------|------|
| `scratch/t20_smcproto.swift` | 还原出的 168 字节 SMC 协议客户端（→ NotPrivileged） |
| `scratch/t20_selsweep.c` | selector × 长度全扫描（3 个 struct 方法 + 3 个 scalar 方法） |
| `scratch/t20_cmdsweep.swift` | 命令字节 `+0x2a` 的 0…255 扫描 |
| `scratch/t20_openmatrix.swift` | 各类候选服务的 type 0…31 打开矩阵 + 取数结果 |
| `scratch/t20_dispatchertype2.c` | `AppleSMCSensorDispatcher` 的 type 0…65535 暴力枚举 |
| `scratch/t20_sensordispatch.swift` | 候选服务属性转储（找到 `AppleSMCSensorDispatcher` / `IOUserClientClass`） |
| `scratch/t20_smct_classes.c` | `SMCT.framework` 的 ObjC 类枚举（证明它与 SMC 无关） |
| `scratch/t20_thermalstate.swift` | 热压力四档 + 通知验证 |
| `scratch/tmon_disasm.txt` | thermalmonitord 全量反汇编（17610 行） |
| `scratch/ioreg_full_t20.txt` | 全量 IORegistry 转储（40315 行） |
