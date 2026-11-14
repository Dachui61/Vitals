# 01 — Can IOReportHub give an unprivileged numeric CPU die temperature on macOS 27?

**Machine:** macOS 27.0 (build 26A425), Apple M6 (Mac mini, Mac18,5), arm64, 16 GB RAM, 12 cores,
`uid=501(liuyu)`, no `sudo`. Xcode Command Line Tools only.

**Artifacts (reusable, verbatim):**
- [`scratch/io_report_temp.swift`](../scratch/io_report_temp.swift) — the IOReportHub investigation tool
  (compiled to `scratch/io_report_temp`, 80 992 bytes, runs clean, exit 0)
- [`scratch/smc_temp.swift`](../scratch/smc_temp.swift) — the **working** unprivileged temperature reader
  (compiled to `scratch/smc_temp`, 86 440 bytes)

---

## Verdict

**CANNOT** — the IOReportHub private IOKit protocol cannot deliver a numeric CPU die temperature to an
unprivileged process on this machine, and the blocker is *not* a permission check on the user client:
the service opens fine, but macOS 27's IOReport channel space contains **no CPU-die-temperature
channel at all** (0 of ~8 450 enumerated channels match "die"), the legacy `'MREP'` descriptor handshake
is gone (methods 2/3/5 answer `kIOReturnBadArgument` = −536870206), and even Apple's own reader
(`/usr/lib/libIOReport.dylib`) stops at the kernel-buffer update with Mach error 268435459 (0x10000003).

**But a numeric CPU temperature IS available unprivileged on macOS 27** — through the *new* SMC library
`/usr/lib/libSMC.dylib` (the successor to the now-dead classic SMC path). Observed live values on this
idle M6: `TH0x` ≈ 51.2 °C, `TH0b` ≈ 50.1 °C, `TMVR` ≈ 52.2 °C, `Tp05` ≈ 63.4 °C, `Tp09` ≈ 72.3 °C;
under 10 s of full CPU load `Tp05` climbed +10.9 °C and `Tp09` +6.3 °C, so the sensors are live.
**Recommendation for Vitals: build the temperature readout on `libSMC.dylib`, not on IOReportHub.**

---

## Evidence

### 1. `IOPerformance.framework` is gone; the implementation moved to a dylib

```
$ ls -d /System/Library/Frameworks/IOPerformance.framework
ls: /System/Library/Frameworks/IOPerformance.framework: No such file or directory

$ otool -L /usr/sbin/systemstats | grep -i report
	/usr/lib/libIOReport.dylib (compatibility version 1.0.0, current version 1.0.0)
	/usr/lib/libpmenergy.dylib (compatibility version 1.0.0, current version 2.0.0)
	/usr/lib/libSMC.dylib (compatibility version 1.0.0, current version 40.0.0)

$ otool -L /usr/bin/powermetrics | grep -i report
	/usr/lib/libIOReport.dylib (compatibility version 1.0.0, current version 1.0.0)
	/usr/lib/libpmenergy.dylib (compatibility version 1.0.0, current version 2.0.0)
```

`libIOReport.dylib` has no file on disk — it lives in the dyld shared cache. It is still `dlopen()`-able
and it exports a *new* C API; the classic `IOReportCopyChannelValues` name is gone:

```
$ ./scratch/probe_dlopen
dlopen("/usr/lib/libIOReport.dylib") = 0x364c57800  err=(none)
   dlsym(IOReportCopyChannelValues) = 0x0
   dlsym(IOReportCopyChannelValue) = 0x0
dlopen("IOPerformance.framework/IOPerformance") = 0x0
   err=dlopen(...): 'IOPerformance.framework/IOPerformance' (no such file, not in dyld cache)
```

The real, current export list (recovered from the dyld cache's linkedit, `dyld_shared_cache_arm64e_x1.79.dyldlinkedit`)
is a modern CoreFoundation-flavoured API. `dlsym` resolves the **plain** C names (no leading underscore):

```
$ ./scratch/probe3
  IOReportCopyAllChannels                plain=0x1ab1848ac underscored=0x0
  IOReportCreateSamples                  plain=0x1ab186f1c underscored=0x0
  IOReportCreateSubscription             plain=0x1ab1864d8 underscored=0x0
  IOReportChannelGetChannelName          plain=0x1ab188af0 underscored=0x0
  IOReportCopyChannelsInCategories       plain=0x1ab187cb8 underscored=0x0
  IOReportCreateNewRawSamplesBuffer      plain=0x1ab1871e4 underscored=0x0
  IOReportSimpleGetIntegerValue          plain=0x1ab1891fc underscored=0x0
```

Full exported surface (67 symbols) includes `IOReportCopyAllChannels`, `IOReportCopyChannelsForDriver`,
`IOReportCopyChannelsInGroup`, `IOReportCopyChannelsInCategories`, `IOReportCreateSubscription`,
`IOReportCreateSamples*`, `IOReportUpdateSamples*`, `IOReportSimpleGetIntegerValue`,
`IOReportChannelGet{ChannelName,ChannelID,Format,Group,SubGroup,Unit,UnitLabel,Categories}`,
`IOReportState*`, `IOReportHistogram*`, `IOReportCreateAggregate`, `IOReportPrune`, `IOReportMergeChannels`,
`IOReportScaleValue`, `IOReportWriteStringUTF8`.

`libIOReport.dylib`'s own string table (dumped from the loaded image) confirms it speaks to the kernel
through the same IOReportHub user client: `IOReportHub`, `Could not open IOReportHub`,
`kIOReportUserClientOpen failed`, `kIOReportUserClientConfigureInterests failed`,
`IOConnectMapMemory() failed`, `createInterestList() failed`, `_updateKernelBuffer() failed`.

### 2. The IOReportHub service and its user client open **unprivileged**

```
$ ioreg -c IOReportHub -w0 -l
+-o IOReportHub  <class IOReportHub, id 0x100000315, registered, matched, active, busy 0 (36 ms), retain 16>
  | {
  |   "CFBundleIdentifier" = "com.apple.iokit.IOReportFamily"
  |   "IOClass" = "IOReportHub"
  |   "IOUserClientClass" = "IOReportUserClient"
  |   "IOProviderClass" = "IOResources"
  | }

$ kmutil showloaded | grep -i report
   29   25 0xfffffe0007b496c0 0xdac  0xdac  com.apple.iokit.IOReportFamily (47) ...
```

The user-client type is **515** (recovered by decoding the ADRP+LDR pair inside
`libIOReport.dylib`'s `IOReportCreateSubscription`, which loads it from a global — the same global Apple's
daemons use). `IOServiceOpen` with it succeeds from uid 501:

```
$ ./scratch/io_report_temp
=== 2. raw IOReportHub user client (unprivileged) ===
  IOServiceMatching("IOReportHub") -> service 0x2313
  IOServiceOpen(type=515) -> kr=0 ((os/kern) successful)  [OPENED]
```

Method map of that user client (raw `IOConnectCallStructMethod` probes, empty input):

```
      sel=0  empty input      -> kr=0 ((os/kern) successful)
      sel=1  empty input      -> kr=0 ((os/kern) successful)
      sel=2  empty input      -> kr=-536870206 ((iokit/common) invalid argument)
      sel=3  empty input      -> kr=-536870206 ((iokit/common) invalid argument)
      sel=4  empty input      -> kr=-536870166 ((iokit/common) a completion routine is required)
      sel=5  empty input      -> kr=-536870206 ((iokit/common) invalid argument)
      sel=6  empty input      -> kr=-536870201 ((iokit/common) unsupported function)
      sel=7  empty input      -> kr=-536870201 ((iokit/common) unsupported function)
```

So the service is **not** privilege-gated; the protocol itself changed.

### 3. The legacy `'MREP'` IOPerformance descriptor handshake is **gone**

Same connection, sending a legacy `IOReportDescriptor` (`magic = 0x4D524550` `'MREP'`,
class filter `0x3A27E83B`):

```
      sel=0  'MREP' descriptor -> kr=-536870206 ((iokit/common) invalid argument)
      sel=1  'MREP' descriptor -> kr=-536870206 ((iokit/common) invalid argument)
      sel=2  'MREP' descriptor -> kr=-536870206 ((iokit/common) invalid argument)
      sel=3  'MREP' descriptor -> kr=-536870206 ((iokit/common) invalid argument)
      sel=4  'MREP' descriptor -> kr=-536870206 ((iokit/common) invalid argument)
      sel=5  'MREP' descriptor -> kr=-536870206 ((iokit/common) invalid argument)
```

Note that selectors 0 and 1 *succeed* with an empty struct but **reject the descriptor** — i.e. the
method numbers survive but the pre-macOS-27 struct-based handshake does not. The macOS 27 protocol
(reconstructed from `libIOReport.dylib`'s disassembly) is:

1. `IOServiceMatching("IOReportHub")` → `IOServiceGetMatchingService` → `IOServiceOpen(service, 515, 0, &conn)`
2. method 0 — "open/negotiate" the user client
3. build an **interest list**: `{ uint32_t count; uint32_t pad; Item items[] }`, `sizeof(Item) == 24`,
   `Item = { uint64_t driverID; uint64_t channelID; uint64_t format; }`
   (`driverID`/`channelID`/`format` come straight out of the legend tuple `LegendChannel` +
   the `DriverID` property)
4. method 2 — "configure interests" (returns the memory index)
5. `IOConnectMapMemory(conn, memIndex, size, &addr, &size, 1)`
6. method 3 — "update kernel buffer" (refreshes the mapped region)

### 4. The macOS 27 IOReport channel space has **no CPU die temperature channel**

`IOReportCopyAllChannels()` returns a CFDictionary `{ QueryOpts, IOReportChannels[] }`; each channel entry
carries `DriverID`, `DriverName`, `IOReportGroupName`, `IOReportSubGroupName`, `IOReportChannelInfo`
and a `LegendChannel = (channelID, format, name)` tuple. Unprivileged, in **0.05 s**:

```
=== 1. IOReport channel space (via /usr/lib/libIOReport.dylib) ===
  total channels enumerated: 8450   (in 0.05 s)
  channels whose name looks temperature-related: 50
    - name='SOC_TVM_PERFCNT_TEMP_REGION0'  group='SoC Stats'  driver='AppleSoCReporter <id 0x100000404>'  format=4295098369
    ... (DCS_/DISP_/SOC_ TVM perf counters) ...
    - name='SOCHOT0_L'  group='SoC Stats'  driver='AppleSoCReporter <id 0x100000404>'  format=8590065666
    - name='SOCHOT1_L'  group='SoC Stats'  driver='AppleSoCReporter <id 0x100000404>'  format=8590065666
    - name='Temperature(0)'  group='ANS2'  driver='RTBuddyIOReportingEndpoint <id 0x100000706>'  format=4295098369
    - name='com.apple.xnu.stackshot_entitlement_report'  group='Hub Stats'  driver='CoreAnalyticsHub <id 0x10000030f>' ...
    - name='MSDU successfully transmits >= 1 attempt'  group='Chip'  driver='IO80211ReporterProxy <id 0x100000dd2>' ...
    - name='Tx HE Attempts 0..15'  group='Interface en1' / 'Rate'  driver='IO80211ReporterProxy ...' ...
  channels matching "die": 0 => NO CPU DIE TEMPERATURE CHANNEL EXISTS
```

The only 50 "temperature-ish" names are: 12 `*_TVM_PERFCNT_TEMP_REGION*` **performance counters**
(SoC/DCS/DISP TVM regions, not temperatures), 2 `SOCHOT0_L`/`SOCHOT1_L` **hot counters**, one
`Temperature(0)` owned by Apple's internal `RTBuddyIOReportingEndpoint` (RTBuddy telemetry, group
`ANS2`), and the rest are Wi-Fi "Tx HE Attempts" counters that merely contain the substring "temp".
**There is no CPU die temperature channel to read.**

### 5. Apple's own reader also stops at the kernel-buffer update

Following Apple's own sequence (`IOReportCopyAllChannels` → `IOReportCreateSubscription` →
raw samples buffer → samples), unprivileged:

```
=== 3. Apple's own read path via libIOReport.dylib ===
  IOReportCopyAllChannels() -> ok (typeid=18)
  IOReportCreateSubscription() -> aggregate=non-nil err=(no error)
  IOReportCreateNewRawSamplesBuffer() -> nil err=NSMachErrorDomain 268435459: The operation couldn’t be completed. _updateKernelBuffer() failed — _updateKernelBuffer() failed
  IOReportCreateSamples() -> nil err=(no error)
```

* `IOReportCreateSubscription()` **succeeds** — the hub accepts the interest list from uid 501.
* The very next step — the method-3 "update kernel buffer" — fails with
  **Mach error 268435459 = 0x10000003 (`KERN_NO_SPACE`)**.
* Reproduced with the full 8 450-channel interest list *and* with a 1-channel filtered interest list
  (only `Temperature(0)`), and through both the direct `dlsym` path and the ObjC path. Same error.

So even Apple's own macOS 27 implementation cannot pull report values from the hub without privilege
on this machine — and `powermetrics`, which does read IOReport values, is root-only anyway.

### 6. The working path: `/usr/lib/libSMC.dylib`

`libSMC.dylib` (also in the dyld cache) exports the modern SMC API:

```
$ strings dyld_shared_cache_arm64e_x1.79.dyldlinkedit | grep -E '^_SMC[A-Za-z0-9_]*$' | sort -u
_SMCAEPopulateChannelInfo        _SMCGetKeyFromIndex          _SMCReadKeyAsNumeric
_SMCAEPopulatePlatform          _SMCGetKeyInfo               _SMCReadKeyAsNumericWithKnownKeyInfo
_SMCOpenAppleSMC                _SMCOpenConnection           _SMCReadKeyWithKnownSize
_SMCCloseConnection             _SMCOpenConnectionWithDefaultService
_SMCAccumGetChannelInfoForKey   _SMCGetAccumStatus          _SMCWriteKeyAsNumeric ...
```

Signatures recovered by disassembling `libSMC.dylib` in the shared cache with lldb:

* `void *SMCOpenConnectionWithDefaultService(void)` — opens the AppleSMC service and returns a connection.
* `int SMCReadKeyAsNumeric(conn, uint32_t key, SMCNumeric *out24, double *outValue)`
  — returns `0` on success, `0xff` on failure; the 4-char key is packed **big-endian**
  (`'T'<<24|'C'<<16|'0'<<8|'P'` = `0x54433050`).
  *Caveat:* the value out-parameter is not documented anywhere; empirically it is an IEEE-754 `double`
  in °C for the temperature keys (raw bit patterns land in `0x4048…0x4052`, i.e. 49–84 °C).

**Observed values, idle, 8 samples over 8 s** (`./scratch/smc_temp --seconds 8`, uid 501):

```
macOS CPU die temperature via /usr/lib/libSMC.dylib (unprivileged, uid=501)
keys: TH0x, TH0a, TH0b, TMVR, Tp05, Tp09
t= 0.0s  TH0x= 51.16 °C  TH0a= 51.16 °C  TH0b= 50.17 °C  TMVR= 52.33 °C  Tp05= 63.88 °C  Tp09= 72.86 °C
t= 1.0s  TH0x= 50.97 °C  TH0a= 50.97 °C  TH0b= 49.98 °C  TMVR= 52.14 °C  Tp05= 63.58 °C  Tp09= 72.34 °C
t= 2.0s  TH0x= 51.35 °C  TH0a= 51.35 °C  TH0b= 50.17 °C  TMVR= 52.33 °C  Tp05= 63.33 °C  Tp09= 72.12 °C
t= 3.0s  TH0x= 51.16 °C  TH0a= 51.16 °C  TH0b= 50.19 °C  TMVR= 52.14 °C  Tp05= 63.28 °C  Tp09= 72.09 °C
t= 4.0s  TH0x= 51.16 °C  TH0a= 51.16 °C  TH0b= 50.19 °C  TMVR= 51.94 °C  Tp05= 63.44 °C  Tp09= 72.50 °C
t= 5.0s  TH0x= 51.16 °C  TH0a= 51.16 °C  TH0b= 49.98 °C  TMVR= 52.14 °C  Tp05= 63.41 °C  Tp09= 72.47 °C
t= 6.0s  TH0x= 51.35 °C  TH0a= 51.35 °C  TH0b= 50.19 °C  TMVR= 52.52 °C  Tp05= 63.16 °C  Tp09= 72.17 °C
t= 7.0s  TH0x= 50.97 °C  TH0a= 50.97 °C  TH0b= 49.98 °C  TMVR= 52.14 °C  Tp05= 63.16 °C  Tp09= 72.05 °C

TH0x  n=8  min= 50.97  max= 51.35  avg= 51.16  (static)
TH0a  n=8  min= 50.97  max= 51.35  avg= 51.16  (static)
TH0b  n=8  min= 49.98  max= 50.19  avg= 50.10  (static)
TMVR  n=8  min= 51.94  max= 52.52  avg= 52.21  (varies — live sensor)
Tp05  n=8  min= 63.16  max= 63.88  avg= 63.40  (varies — live sensor)
Tp09  n=8  min= 72.05  max= 72.86  avg= 72.33  (varies — live sensor)

per-read cost: 123.0 µs  (1 Hz sampling is comfortably viable)
```

**Under load** (4 × `/usr/bin/yes`, i.e. all 12 cores busy, 10 samples over 10 s):

```
generating load with 4 x /usr/bin/yes ...
t= 0.0s  TH0x= 50.39 °C  TH0a= 50.39 °C  TH0b= 49.68 °C  TMVR= 51.35 °C  Tp05= 66.44 °C  Tp09= 77.91 °C
t= 1.0s  TH0x= 50.39 °C  TH0a= 50.39 °C  TH0b= 49.51 °C  TMVR= 51.55 °C  Tp05= 69.84 °C  Tp09= 78.94 °C
t= 2.0s  TH0x= 50.58 °C  TH0a= 50.58 °C  TH0b= 49.67 °C  TMVR= 51.55 °C  Tp05= 72.44 °C  Tp09= 80.84 °C
t= 3.0s  TH0x= 50.39 °C  TH0a= 50.39 °C  TH0b= 49.51 °C  TMVR= 51.74 °C  Tp05= 73.97 °C  Tp09= 81.80 °C
t=  4.0s  TH0x= 50.78 °C  TH0a= 50.78 °C  TH0b= 49.67 °C  TMVR= 51.75 °C  Tp05= 74.69 °C  Tp09= 82.52 °C
t=  5.0s  TH0x= 50.58 °C  TH0a= 50.58 °C  TH0b= 49.68 °C  TMVR= 51.94 °C  Tp05= 75.23 °C  Tp09= 82.98 °C
t=  6.0s  TH0x= 50.58 °C  TH0a= 50.58 °C  TH0b= 49.33 °C  TMVR= 51.94 °C  Tp05= 75.56 °C  Tp09= 83.31 °C
t=  7.0s  TH0x= 50.77 °C  TH0a= 50.77 °C  TH0b= 49.35 °C  TMVR= 51.94 °C  Tp05= 75.84 °C  Tp09= 83.50 °C
t=  8.0s  TH0x= 50.77 °C  TH0a= 50.77 °C  TH0b= 49.68 °C  TMVR= 51.94 °C  Tp05= 77.33 °C  Tp09= 84.19 °C
t=  9.0s  TH0x= 50.98 °C  TH0a= 50.98 °C  TH0b= 49.51 °C  TMVR= 52.52 °C  Tp05= 77.27 °C  Tp09= 84.25 °C

Tp05  n=10  min= 66.44  max= 77.33  avg= 73.86  (varies — live sensor)   <-- +10.9 °C under load
Tp09  n=10  min= 77.91  max= 84.25  avg= 82.02  (varies — live sensor)   <-- +6.3 °C under load
TH0x  n=10  min= 50.39  max= 50.98  avg= 50.62  (varies — live sensor)   <--  +0.6 °C under load
```

Plausibility: the ticket expected ~30–45 °C for an *idle* M6. These readings are higher, but the box
had been compiling Swift and running `lldb` continuously during the session, and `Tp09` is already
72 °C at "idle" — i.e. these are die/hotspot sensors, not an ambient idling die. `TH0x`/`TH0a`/`TH0b`
behave like thermal-head (heatsink) sensors and barely move under CPU load.

**Which key is the CPU die is not yet established** — see *Open questions*. `Tp05` tracks CPU load most
strongly (+10.9 °C) and is the better CPU-die candidate; `Tp09` is hotter and less CPU-coupled
(candidate: GPU die or shared SoC hotspot). The classic Intel-ish keys are absent on this Mac:

```
$ ./scratch/smc_sweep
TH0x  info: 000000008500000001000000010020000000000004000000   readNum rc=0 sz=0x40497bdf00000000 ...
TH0a  info: ...                                                 readNum rc=0 sz=0x40497bdf00000000 ...
TH0b  info: ...                                                 readNum rc=0 sz=0x4048ff2600000000 ...
TMVR  info: ...                                                 readNum rc=0 sz=0x4049f7be00000000 ...
Tp09  info: ...                                                 readNum rc=0 sz=0x4052030000000000 ...
Tp05  info: ...                                                 readNum rc=0 sz=0x404f8c0000000000 ...
--- done ---
```

(`TC0P`, `TC0F`, `TCHP`, `TCXC`, `TM0P`, `TG0D`, `TG0F`, `TG1F`, `TH1A`, `TH1C`, … all return
`SMCGetKeyInfo` rc = −3, i.e. absent on this machine.)

**Corroboration that this is the sanctioned path**: Apple's own `/usr/sbin/systemstats` links
`libSMC.dylib` and embeds exactly these key names:

```
$ strings -a /usr/sbin/systemstats | grep -E '^T[A-Z]' | sort -u
TA0V  TB0T  TC0F  TC0P  TCHP  TCID  TCMb  TCXC  TCXc  TG0D  TG0F  TG1F  TGDF
TH0A  TH0B  TH0C  TH0F  TH0T  TH0X  TH0a  TH0b  TH0x  TH1A  TH1C  TH1a  ...
TJ0F  TKBV  TL0V  TL1V  TM0P  TM0V  TMVR  TP9a  TPM1  TPMP  TPMV  TPSP  TS0V ...
```

### 7. Performance

| operation | cost |
|---|---|
| `SMCReadKeyAsNumeric` (one key) | **96.8–123.0 µs** (200-read average) |
| reading all 6 temperature keys | ≈ 0.7 ms |
| `IOReportCopyAllChannels()` (full enumeration, one-shot) | 0.05 s (8 450 channels) |
| `IOReportCreateSubscription()` | succeeds, but its follow-up read fails |

1 Hz sampling is **comfortably viable** (0.12 ms per read → 0.012 % duty cycle). For a menu-bar app,
2–5 s sampling with light smoothing is more than enough.

---

## Implementation notes (what a shipping Vitals implementation must do)

### A. Temperature source: `libSMC.dylib`, not IOReportHub

```swift
// 1) probe: never assume the library or the symbols exist
guard let h = dlopen("/usr/lib/libSMC.dylib", RTLD_NOW | RTLD_LOCAL) else { /* temperature unavailable */ }
guard let openSym = dlsym(h, "SMCOpenConnectionWithDefaultService"),
      let readSym = dlsym(h, "SMCReadKeyAsNumeric") else { /* unavailable */ }

// 2) keep the connection open for the lifetime of the app
let open = unsafeBitCast(openSym, to: (@convention(c) () -> UnsafeMutableRawPointer?).self)
let read = unsafeBitCast(readSym, to: (@convention(c) (UnsafeMutableRawPointer?, UInt32,
                                                     UnsafeMutableRawPointer?,
                                                     UnsafeMutablePointer<Double>?) -> Int32).self)

// 3) keys are big-endian packed 4-char codes
func key(_ s: String) -> UInt32 { /* 'T'<<24|'C'<<16|'0'<<8|'P' */ }

// 4) read; rc == 0 means success, the double out-param is the value in °C
```

**Do not** link `IOPerformance.framework` (gone) and **do not** try to link `libIOReport.dylib` either —
it has no header and its C++ object model is not usable from Swift; `dlopen` + `dlsym` is the only
tractable route, and the only thing worth taking from it is the *channel enumeration* if a project
ever needs IOReport counters.

### B. Capability probing / degradation ladder

The app must be able to detect breakage and fall back automatically. Recommended ladder at startup:

1. `dlopen("/usr/lib/libSMC.dylib")` → if it fails, temperature is **不可用** (per `GLOSSARY.md`,
   that is *not* `0`).
2. `dlsym` for `SMCOpenConnectionWithDefaultService` and `SMCReadKeyAsNumeric` → if missing, unavailable.
3. `SMCOpenConnectionWithDefaultService()` → NULL means the SMC user client is closed to us
   (entitlement change in a future macOS) → unavailable.
4. Probe a **candidate key list** (`TH0x`, `TH0a`, `TH0b`, `TMVR`, `Tp05`, `Tp09`, plus the classic
   `TC0P`/`TC0F`/`TCHP` for other Macs) and keep the ones that return rc == 0 with a plausible
   temperature (say −40 … 150 °C). Do **not** hard-code one key: the key set is chip-dependent.
5. Among the live keys, pick the CPU-die candidate by the response to CPU load (see Open questions),
   or ship a per-chip table.
6. Re-probe periodically (e.g. every 5 min, or after a wake) rather than once at launch: a key can
   disappear across sleep/wake or after a firmware update.

### C. Error handling

* `SMCReadKeyAsNumeric` returns `0` on success and `0xff` (255) on failure — check it; do not read the
  out-param on failure.
* A key that exists but is momentarily unreadable returns failure; treat one failed read as
  "keep the previous value", not as 0 °C.
* Never display a stale value as if it were live — carry a timestamp and mark the reading as
  unavailable if it is older than a few sampling periods.

### D. Other IOReport channels that *are* readable (and temperature-adjacent)

If the project ever wants IOReport counters (CPU power, residency, frequencies), note that on this
machine **values cannot be pulled unprivileged** (§5). The channels exist and are enumerable, but the
data path is closed to uid 501. The closest temperature-adjacent names are:

| channel | group | driver | what it is |
|---|---|---|---|
| `Temperature(0)` | `ANS2` | `RTBuddyIOReportingEndpoint` | Apple's internal telemetry; the only literally-named temperature channel, but RTBuddy is not CPU die temp and is not readable here |
| `SOCHOT0_L`, `SOCHOT1_L` | `SoC Stats` | `AppleSoCReporter` | "hot" event counters, not degrees |
| `SOC_/DCS_/DISP_TVM_PERFCNT_TEMP_REGION0..3` | `SoC Stats` | `AppleSoCReporter` | TVM performance counters in thermal regions — again counters, not degrees |

Nothing in the IOReport space is a CPU die temperature in °C.

### E. What else exists on macOS 27 (not IOReport, not SMC)

* `pmset -g therm` → `Note: No thermal pressure level has been recorded` (idle; no warning levels).
* `sysctl kern.thermal_pressure` → `unknown oid` on macOS 27.
* Thermal *pressure* is therefore best obtained from the IOKit HID-event thermal-notification path
  (`IOHIDEventSystemClient`) — worth a separate ticket if a "thermal pressure" indicator is wanted.

---

## Risks

1. **Everything here is private API.** `libSMC.dylib` has no public header, no `__API_AVAILABLE`
   deprecation attribute and no documented ABI. There is **no deprecation signal** in the binary
   (no `deprecated` string, no versioned-header warning), and it is linked by two first-party daemons
   (`/usr/sbin/systemstats`, `/usr/bin/powermetrics`), so it is "supported in practice" — but Apple can
   rename keys, change the numeric encoding, or gate the SMC user client behind an entitlement in any
   point release without notice.
2. **Key naming is chip- and model-specific.** This M6 exposes `Tp05`/`Tp09`/`TH0x`; the classic
   `TC0P`/`TC0F`/`TCHP` are absent. Another Mac may expose a different set, so a single hard-coded
   key is a latent bug.
3. **The semantic identity of the keys is unproven.** `Tp05` and `Tp09` are *some* die-level sensors;
   whether one is the CPU die, the GPU die, or a shared SoC hotspot is not established. Showing the
   wrong one in a menu bar is a correctness bug, not a cosmetic one.
4. **The IOReportHub route is strictly worse.** It requires a private struct layout, a private
   user-client type (515), a private interest-list protocol, and it still fails unprivileged at the
   kernel-buffer step. Do not build on it.
5. **The classic SMC route is dead** (`AppleSMCUserClient`: zero matches; `AppleSMCKeysEndpoint`:
   every read-key selector returns `kIOReturnBadArgument`), so `libSMC.dylib` is the *only* remaining
   unprivileged route — there is no more-stable API to fall back to if Apple closes it.
6. **Sandboxing / notarisation.** A sandboxed, notarised Vitals.app can still `dlopen` a system dylib,
   but `dlopen` of a non-bundled path may be blocked by the hardened-runtime library-validation policy
   in some configurations. Verify on the shipping build; `dlopen` with `RTLD_NOW` of
   `/usr/lib/libSMC.dylib` worked fine from a plain (non-signed) binary here, but the shipped app is
   signed.
7. **Thermal throttling / accuracy.** Die sensors near the throttle point are noisy and hysteretic;
   the readings above jump by ~1 °C between samples. Use a moving average and consider clamping.

---

## Open questions

1. **Which key is the CPU die?** `Tp05` tracks CPU load most strongly (+10.9 °C over 10 s of full load)
   and `Tp09` is hotter but less CPU-coupled (+6.3 °C). Needs a disambiguation test:
   a Metal/GPU-only load (does `Tp09` move while `Tp05` does not?) and/or a comparison against
   `powermetrics` "CPU die temperature" output (needs root — to be handed to the user as a one-off
   command).
2. **Is 72 °C at "idle" normal for this box?** `Tp09` sits at 72 °C while the machine is otherwise
   idle; that is high for a CPU die. Either the sensor is not the CPU die, the box has a hot
   environment, or the machine was not really idle (it had been compiling Swift).
3. **Which key is portable across Macs?** The `Tp`/`TH` family appears to be Apple Silicon specific.
   What do Intel Macs expose on macOS 27, and is there a single key that means "CPU die" everywhere?
4. **Is the IOReportHub kernel-buffer failure a policy or a capacity issue?** `0x10000003`
   (`KERN_NO_SPACE`) is ambiguous. A root comparison would tell us whether the buffer is simply not
   allocated for unprivileged clients (policy) or whether the interest list was too large (capacity).
   Needs `sudo`, which the agents do not have.
5. **Is the failure specific to this machine or to macOS 27 generally?** Only one machine was tested.
6. **The exact 10-argument user-client entry point** that `libIOReport.dylib` uses for methods 2 and 3
   was identified by call site (not by symbol name), and the interest-list layout
   (`{u32 count; {u64 driverID, u64 channelID, u64 format}[]}`) was inferred from the disassembly rather
   than confirmed by a working raw reader. Confirming it would make a *root* IOReport reader possible.
7. **Is there a supported API at all?** If Vitals must ship a non-private temperature source, macOS 27
   offers none: `powermetrics` is root-only, and the public `ProcessInfo.thermalState` only reports
   nominal/serious/critical. Worth deciding whether Vitals accepts a private-API dependency.
8. **Does `IOReportCopyAllChannels()` still work when run from a sandboxed app?** Untested; the
   enumeration path is the only IOReport functionality still reachable unprivileged.

---

## Appendix — reusable sources

### `scratch/smc_temp.swift` (working temperature reader; the artifact to reuse)

```swift
// smc_temp.swift — unprivileged CPU die temperature on macOS 27 (Apple M6) via /usr/lib/libSMC.dylib
//
// WHY THIS EXISTS
// ---------------
// Ticket 01 asked whether IOReportHub can provide a numeric CPU die temperature
// unprivileged on macOS 27. It cannot (see scratch/io_report_temp.swift + the report).
// macOS 27 however ships a *new* SMC API in /usr/lib/libSMC.dylib, which IS
// dlopen()-able from user space and DOES return numeric temperatures.
// Apple's own /usr/sbin/systemstats links libSMC.dylib and uses the same keys.
//
// BUILD (this machine: Command Line Tools only, $TMPDIR module cache not writable)
//   swiftc -O -parse-as-library \
//          -module-cache-path "$PWD/.modulecache" -Xcc -fmodules-cache-path="$PWD/.modulecache" \
//          -o scratch/smc_temp scratch/smc_temp.swift
//
// RUN
//   scratch/smc_temp              # idle sampling, 1 Hz
//   scratch/smc_temp --load       # spawns busy loops and samples under load
//   scratch/smc_temp --seconds 20

import Foundation
import Darwin

// MARK: - libSMC.dylib bindings (private, but exported from the dyld shared cache)

typealias SMCOpenDefaultService = @convention(c) () -> UnsafeMutableRawPointer?
typealias SMCReadKeyAsNumeric = @convention(c) (
    UnsafeMutableRawPointer?,      // connection
    UInt32,                        // 4-char key, big-endian packed
    UnsafeMutableRawPointer?,      // out: 24-byte SMCNumeric struct
    UnsafeMutablePointer<Double>?  // out: value
) -> Int32
typealias SMCGetKeyInfo = @convention(c) (
    UnsafeMutableRawPointer?,
    UInt32,
    UnsafeMutableRawPointer?
) -> Int32

enum SMCError: Error, CustomStringConvertible {
    case dlopenFailed(String)
    case symbolMissing(String)
    case openFailed
    case readFailed(Int32)

    var description: String {
        switch self {
        case .dlopenFailed(let s): return "dlopen(/usr/lib/libSMC.dylib) failed: \(s)"
        case .symbolMissing(let s): return "dlsym(\(s)) returned NULL"
        case .openFailed: return "SMCOpenConnectionWithDefaultService() returned NULL"
        case .readFailed(let rc): return "SMCReadKeyAsNumeric() failed, rc=\(rc)"
        }
    }
}

final class SMCClient {
    private let handle: UnsafeMutableRawPointer
    private let openDefault: SMCOpenDefaultService
    private let readKey: SMCReadKeyAsNumeric
    private let keyInfo: SMCGetKeyInfo
    let connection: UnsafeMutableRawPointer

    init() throws {
        guard let h = dlopen("/usr/lib/libSMC.dylib", RTLD_NOW | RTLD_LOCAL) else {
            throw SMCError.dlopenFailed(String(cString: dlerror()))
        }
        handle = h
        guard let p = dlsym(h, "SMCOpenConnectionWithDefaultService") else {
            throw SMCError.symbolMissing("SMCOpenConnectionWithDefaultService")
        }
        openDefault = unsafeBitCast(p, to: SMCOpenDefaultService.self)
        guard let p = dlsym(h, "SMCReadKeyAsNumeric") else {
            throw SMCError.symbolMissing("SMCReadKeyAsNumeric")
        }
        readKey = unsafeBitCast(p, to: SMCReadKeyAsNumeric.self)
        guard let p = dlsym(h, "SMCGetKeyInfo") else {
            throw SMCError.symbolMissing("SMCGetKeyInfo")
        }
        keyInfo = unsafeBitCast(p, to: SMCGetKeyInfo.self)

        guard let conn = openDefault() else { throw SMCError.openFailed }
        connection = conn
    }

    /// Apple packs a 4-char SMC key big-endian: 'T','C','0','P' -> 0x54433050.
    static func key(_ s: String) -> UInt32 {
        let b = Array(s.utf8)
        precondition(b.count == 4)
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    /// Returns the numeric value of a key, or nil if the key is absent/unreadable.
    func read(_ keyString: String) -> Double? {
        var numeric = [UInt8](repeating: 0, count: 24)
        var value: Double = 0
        let rc = numeric.withUnsafeMutableBytes { raw -> Int32 in
            readKey(connection, SMCClient.key(keyString),
                    raw.baseAddress, &value)
        }
        return rc == 0 ? value : nil
    }

    /// Raw SMCKeyData-like info blob for a key (useful for diagnostics).
    func info(_ keyString: String) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: 64)
        let rc = buf.withUnsafeMutableBytes { raw -> Int32 in
            keyInfo(connection, SMCClient.key(keyString), raw.baseAddress)
        }
        return rc == 0 ? Array(buf[0..<24]) : nil
    }
}

// MARK: - keys that carry CPU / SoC temperature on Apple Silicon

/// Keys observed readable on this Mac (Apple M6 / Mac18,5, macOS 27.0 26A425).
let temperatureKeys = ["TH0x", "TH0a", "TH0b", "TMVR", "Tp05", "Tp09"]

func fmt(_ d: Double?) -> String {
    guard let d else { return "  n/a " }
    return String(format: "%6.2f °C", d)
}

// MARK: - load generation (so we can prove the values move)

func startBusyLoops(count: Int) -> [Process] {
    var procs: [Process] = []
    for _ in 0..<count {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        procs.append(p)
    }
    return procs
}

// MARK: - entry point

@main
struct Tool {
    static func main() {
        let args = CommandLine.arguments
        var loadProcs: [Process] = []
        defer { loadProcs.forEach { $0.terminate() } }
        let wantLoad = args.contains("--load")
        let seconds = {
            if let i = args.firstIndex(of: "--seconds"), i + 1 < args.count, let s = Int(args[i + 1]) { return s }
            return 6
        }()

        print("macOS CPU die temperature via /usr/lib/libSMC.dylib (unprivileged, uid=\(getuid()))")
        print("keys: \(temperatureKeys.joined(separator: ", "))")

        let smc: SMCClient
        do {
            smc = try SMCClient()
        } catch {
            FileHandle.standardError.write(("error: \(error)\n").data(using: .utf8)!)
            exit(1)
        }

        if wantLoad {
            print("generating load with 4 x /usr/bin/yes ...")
            loadProcs = startBusyLoops(count: 4)
        }

        var samples: [[Double?]] = []
        let t0 = Date()
        for i in 0..<seconds {
            let row = temperatureKeys.map { smc.read($0) }
            samples.append(row)
            let stamp = String(format: "t=%4.1fs", Date().timeIntervalSince(t0))
            print("\(stamp)  " + temperatureKeys.enumerated().map { (idx, k) in "\(k)=\(fmt(row[idx]))" }.joined(separator: "  "))
            if i + 1 < seconds { Thread.sleep(forTimeInterval: 1.0) }
        }

        // MARK: - statistics

        print("")
        for (idx, k) in temperatureKeys.enumerated() {
            let vals = samples.compactMap { $0[idx] }
            guard !vals.isEmpty else { print("\(k): no samples"); continue }
            let mn = vals.min()!, mx = vals.max()!
            let avg = vals.reduce(0, +) / Double(vals.count)
            print(String(format: "%-5s n=%d  min=%6.2f  max=%6.2f  avg=%6.2f  %@",
                         (k as NSString).utf8String!, vals.count, mn, mx, avg,
                         (mx - mn) > 0.5 ? "(varies — live sensor)" : "(static)"))
        }

        // MARK: - cost per sample

        let t = Date()
        let reps = 200
        for _ in 0..<reps { _ = smc.read("TH0x") }
        let perSample = Date().timeIntervalSince(t) / Double(reps)
        print(String(format: "\nper-read cost: %.1f µs  (1 Hz sampling is %@)",
                     perSample * 1e6, perSample < 0.5 ? "comfortably viable" : "NOT viable"))
    }
}
```

### `scratch/io_report_temp.swift` (IOReportHub investigation tool)

Full source is in [`scratch/io_report_temp.swift`](../scratch/io_report_temp.swift) (229 lines). It:

1. `dlopen`s `/usr/lib/libIOReport.dylib`, calls `IOReportCopyAllChannels()` and lists every channel whose
   name contains `temp`/`therm`/`die`/`hot`/`celsius`, plus the count of channels matching `die`;
2. opens `IOReportHub` with `IOServiceOpen(type = 515)` and probes user-client methods 0–7 with an empty
   struct and with the legacy `'MREP'` descriptor, printing the raw `kern_return_t` for each;
3. runs Apple's own read path (`IOReportCopyAllChannels` → `IOReportCreateSubscription` →
   `IOReportCreateNewRawSamplesBuffer` → `IOReportCreateSamples`) and prints the exact `CFError`.

Build/run:

```sh
swiftc -O -parse-as-library \
       -module-cache-path "$PWD/.modulecache" -Xcc -fmodules-cache-path="$PWD/.modulecache" \
       -o scratch/io_report_temp scratch/io_report_temp.swift
./scratch/io_report_temp
```

---

## Provenance of the primary sources used

| claim | source |
|---|---|
| `IOPerformance.framework` removed; `libIOReport.dylib` is the replacement | `otool -L /usr/sbin/systemstats`, `otool -L /usr/bin/powermetrics`, `dlopen` probe |
| modern `IOReport*` export list | `strings dyld_shared_cache_arm64e_x1.79.dyldlinkedit` + `dlsym` probe |
| `libIOReport` protocol internals (interest list, selectors 0/2/3, `IOConnectMapMemory`) | `lldb` disassembly of `libIOReport.dylib` in the shared cache (`scratch/libioreport.disasm.txt`) |
| IOReportHub service + kext | `ioreg -c IOReportHub -w0 -l`, `kmutil showloaded` |
| user-client type 515 | ADRP+LDR decode of `libIOReport.dylib`'s `IOReportCreateSubscription` data global (`scratch/globals2.c`) |
| complete channel list | `IOReportCopyAllChannels()` at runtime (`scratch/dump_channels.c` → `scratch/all_channels.tsv`, 8 448 rows) |
| SMC API + signatures | `lldb` disassembly of `libSMC.dylib` (`SMCOpenConnectionWithDefaultService`, `SMCReadKeyAsNumeric`, `SMCGetKeyInfo`) |
| live temperature values | `scratch/smc_temp.swift` runs above |
| classic SMC path dead | prior ticket probing (`scratch/ioreg_applesmc.txt`): `AppleSMCUserClient` zero matches, `AppleSMCKeysEndpoint` reads → `kIOReturnBadArgument` |

No git branch, commit or merge was created for this investigation.
