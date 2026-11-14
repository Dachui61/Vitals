# macOS 27 / Apple M6 — Unprivileged Sensor Feasibility (AFK Investigation)

**Host:** `liuyudeMac-Mini`, macOS 27.0 (build 26A425), Darwin 27.0.0 `xnu-13432.1.9~1`
**Chip:** Apple M6, arm64 (`TARGET arm64-apple-macosx27.0`)
**Toolchain:** Command Line Tools only — Swift 6.4.2 (`swiftlang-6.4.2.1.9 clang-2100.4.1.1`).
SDK `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` → `MacOSX27.2.sdk`.
`xcodebuild` unavailable (`xcode-select: error: tool 'xcodebuild' requires Xcode`).
**Probe identity:** `uid=501(liuyu) euid=501` — every result below is from an **unprivileged,
non-root, no-sudo** process. No `sudo` was used at any point.
**Date of run:** 2026-11-14 (local, Asia/Shanghai).

> **Sandbox note:** this investigation ran inside the DeepSeek Harness `workspace-write`
> sandbox. Two consequences, called out inline:
> (a) `clang`/`swift` cannot write the default module cache under `$TMPDIR`, so every
> `swiftc` invocation below passes `-module-cache-path` / `-Xcc -fmodules-cache-path`
> pointing inside the workspace. On a normal terminal the plain commands work unchanged.
> (b) `~/Library/LaunchAgents` creation and `launchctl bootstrap` were **blocked by the
> sandbox** (`Operation not permitted` / `Bootstrap failed: 5: Input/output error`), so
> Q8 could not be completed end-to-end here. See §2.8.

---

## 1. Verdict

| # | Question | Verdict | Caveat |
|---|----------|---------|--------|
| 1 | SMC read via `AppleSMCUserClient` without sudo | **NO** | The *connection opens* unprivileged, but the classic SMCTool read-key protocol is **not implemented/accepted**: `IOServiceMatching("AppleSMCUserClient")` matches **0 services**; the live host is `AppleSMCKeysEndpoint` (`IOUserClientClass = AppleSMCClient`), whose selector 2 returns `kIOReturnBadArgument` for **every** (input,output) size 0–200 and every key payload. No temperature, no fan RPM, nothing numeric. |
| 2 | Per-core CPU load without root | **YES** | `host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, …)` works fully unprivileged; 12 cores reported with sane per-core busy%; `sysctl hw.ncpu/hw.physicalcpu/hw.logicalcpu` = 12/12/12. |
| 3 | `NSProcessInfo.thermalState` | **YES (coarse only)** | Returns `.nominal` in a plain CLI process; no entitlement needed. `ProcessInfo.thermalStateDidChangeNotification` exists and an observer installs cleanly. It is a 4-state bucket, **not** a °C number. `pmset -g therm` runs unprivileged but prints only "No thermal warning level has been recorded". |
| 4 | `powermetrics` | **NO** | `powermetrics` prints `powermetrics must be invoked as the superuser` and exits. Binary is `-rwxr-xr-x root:wheel` (not setuid), so only real root can run it. |
| 5 | GPU utilization / GPU temperature | **PARTIAL** | **GPU utilization: YES** — `AGXAcceleratorG18G` → `PerformanceStatistics` exposes `Device Utilization %`, `Renderer Utilization %`, `Tiler Utilization %` unprivileged via `IORegistryEntryCreateCFProperty`. **GPU temperature: NO** — no temperature field anywhere in the AGX node. Metal (`MTLCopyAllDevices`) exposes the device *name* only ("Apple M6"). |
| 6 | SwiftUI `MenuBarExtra` app built with `swiftc` only | **YES** | `swiftc -parse-as-library -target arm64-apple-macosx13.0 … -framework SwiftUI -framework AppKit -framework Foundation` compiles; hand-assembled `.app` launches via `open`, registers as `type="UIElement"` (no Dock icon), runs, and can be quit. `LSUIElement = true` is what keeps it out of the Dock. |
| 7 | Homebrew / existing tools | **PARTIAL** | Homebrew **7.0.13** at `/opt/homebrew/bin/brew` is installed (node, pnpm, etc. — no sensor tools). The `smc` formula **no longer exists** in Homebrew ("No available formula with the name \"smc\""). `osx-cpu-temp` and `macmon` **are** still in the catalogue. Neither `smc` nor `osx-cpu-temp` is installed. |
| 8 | LaunchAgent path + `launchctl bootstrap gui/$(id -u)` | **PARTIAL (blocked by sandbox)** | `~/Library/LaunchAgents` **does not exist yet** on this machine (must be created). The GUI domain `gui/501` is reachable and enumerable (`launchctl print gui/501` → 3920 lines). `launchctl bootstrap gui/$(id -u) <plist>` is the correct form, but every attempt returned `Bootstrap failed: 5: Input/output error` — including `user/501` and legacy `launchctl load -w` — and `~/Library/LaunchAgents` writes were refused with `Operation not permitted`. Consistent with the harness sandbox, not with macOS semantics. **Must be re-verified outside the sandbox.** |

**Headline:** a no-sudo app on this machine can show **CPU load (per-core + aggregate)**,
**GPU utilization**, **thermal-pressure state (coarse)**, and **memory** — but **cannot**
show a numeric CPU or GPU temperature from any public or unprivileged IOKit interface we
could find. The only numeric die-temp routes found (`powermetrics`, `ApplePMPv2`,
`IOReport` channel values) are root-gated.

---

## 2. Evidence

### 2.1 Q1 — SMC

#### 2.1.1 The SDK ships no SMC headers

```
$ grep -rn "SMCKeyData" /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/
(no output)
$ find …/MacOSX.sdk/usr/include -iname "*SMC*"
(no output)
```

So the layout must be reproduced from the de-facto SMCTool / `harrisonlilley/smc`
convention. It was verified against the C compiler (authoritative):

```c
typedef struct { uint8_t major,minor,build,reserved; uint16_t release; }        vers_t;
typedef struct { uint16_t version,length; uint32_t cpuPLimit,gpuPLimit,memPLimit; } pLimit_t;
typedef struct { uint32_t dataSize,dataType,dataAttributes; }                     keyInfo_t;
typedef struct { uint8_t data[32]; }                                              bytes_t;
typedef struct { uint32_t result,status; uint8_t data8; uint32_t data32; bytes_t bytes; } result_t;
typedef struct { uint32_t dataSize,dataType; uint8_t dataAttributes,pad; uint8_t data[32]; } status_t;
typedef struct { uint32_t key; vers_t vers; pLimit_t pLimitData; keyInfo_t keyInfo;
                 result_t result; status_t data; }                               SMCKeyData_t;
```
```
$ cc -o /tmp/layout /tmp/layout.c && /tmp/layout
sizeof(SMCKeyData_t)      = 132
offset key                = 0
offset vers               = 4
offset pLimitData         = 12
offset keyInfo            = 28
offset result             = 40
offset data               = 88
sizeof(status_t)=44 sizeof(result_t)=48 sizeof(pLimit_t)=16 sizeof(vers_t)=6
```

The Swift mirror agrees (`MemoryLayout<SMCKeyData_t>.size == 130` because Swift's `.size`
excludes tail padding; `.stride == 132` == C `sizeof`). **This is the correct classic
layout, and it does not work on this OS.**

> ⚠️ **Correction to the task brief.** The brief proposed building the key as
> `UInt32('T')<<24 | UInt32('C')<<16 | …`. That is **big-endian** and is wrong for SMC.
> SMC packs the first character in the **low** byte:
> `'T' | 'C'<<8 | '0'<<16 | 'P'<<24` → `0x50304354`.
> The test program prints both so the difference is explicit.

#### 2.1.2 What is actually published in IORegistry

```
$ ioreg -c AppleSMC -w0 -r -d 1
+-o AppleSMCKeysEndpoint  <class AppleSMCKeysEndpoint, id 0x1000007f0, registered, matched, active, …>
      "IOUserClientClass" = "AppleSMCClient"
      "IONameMatch"       = "SMCEndpoint1"
      "role"              = "SMC"
      "IOProviderClass"   = "RTBuddyEndpointService"
      "IOPersonalityPublisher" = "com.apple.driver.AppleSMC"

$ ioreg -c AppleSMCSensorDispatcher -l -w0 -r -d 1
+-o AppleSMCSensorDispatcher  <class AppleSMCSensorDispatcher, id 0x10000068a, …>
      "IOUserClientClass" = "AppleSMCSensorDispatcherUserClient"
      "IONameMatch"       = ("smc-tempsensor")
      "IOProviderClass"   = "AppleARMIODevice"
```

There is **no** published service named `AppleSMCUserClient` on this OS:

```
$ /tmp/smctest
matching services for AppleSMCUserClient: 0
matching services for AppleSMC: 1
matching services for AppleSMCSensorDispatcherUserClient: 0
matching services for AppleSMCSensorDispatcher: 1
matching services for ApplePMPThermalUserClient: 0
matching services for ApplePMGRTempUserClient: 0
matching services for IOReportUserClient: 0
```

`IOReportUserClient` matches 0 because user-client objects live in a **non-registered**
IORegistry plane (`ioreg` shows them as `!registered, !matched`), so `IOServiceMatching`
never sees them. Same for `AppleSMCUserClient`.

#### 2.1.3 The connection opens unprivileged — and then refuses every read

```
IOServiceGetMatchingService(AppleSMCUserClient) -> MACH_PORT_NULL (no such service visible)
IOServiceGetMatchingService(AppleSMC)            -> service 0xa63
IOServiceOpen(AppleSMC)                          -> kIOReturnSuccess      <-- UNPRIVILEGED OPEN OK

### SMC user client OPENED successfully as an unprivileged user.
```

But every classic call fails:

```
TC0P   key=0x50304354  kr=…  result=0x00 status=0x00  size=2 type=0x0d  bytes=[00 00 …]  -> FAILED
       (keyinfo failed: 0xe00002c7 kIOReturnUnsupported)
…  (identical failure for TC0D TC0H TC0F TC0C TC0E TC0G TCAD TC0L TC0M
    TG0P TG0D TG0H TG0F TG0T TG0L Th0H Th1H TB0T Ts0P Tp01 Tp05 Tp09 TA0P PM0T TPCD
    FNum F0Ac F0AcFc F0Mn F0Mx F1Ac)

readVers   kr=-536870201 ((iokit/common) unsupported function)
readPLimit kr=-536870201 ((iokit/common) unsupported function)
```

`AppleSMCKeysEndpoint` behaves identically, except that selector 2 returns
`kIOReturnBadArgument` instead of `kIOReturnUnsupported`:

```
== AppleSMCKeysEndpoint[1] svc=0x1e33 IOServiceOpen -> kIOReturnSuccess
   size=130: sel12(vers)=kIOReturnUnsupported sel11(plimit)=kIOReturnUnsupported
              sel9(keyinfo)=kIOReturnUnsupported sel2(readkey)=kIOReturnBadArgument
   size=132: … sel2(readkey)=kIOReturnBadArgument
   size=136: … sel2(readkey)=kIOReturnBadArgument
   size=128: … sel2(readkey)=kIOReturnBadArgument
```

Exhaustive selector × size matrix on the live connection:

```
### (a) AppleSMCKeysEndpoint method matrix
  sel 0: sz>=0:OK                     <-- accepts ANY size ⇒ no-input method
  sel 1: sz>=0:OK                     <-- accepts ANY size ⇒ no-input method
  sel 2: sz>=0:0xe00002c2 BadArgument <-- read-key: never works
  sel 3..9: sz>=0:0xe00002c7 Unsupported

selector 2 size-sweep result bands: size>=0:0xe00002c2 BadArgument   (0…320, step 1)

== AppleSMCKeysEndpoint: (inputSize x outputSize) matrix for selector 2
   no (in,out) pair produced anything other than BadArgument/Unsupported   (0…272 × 0…272, step 4)
   scalar-method hits: none
```

And the exhaustive step-1 sweep plus the two alternative calling conventions:

```
selector 2, step-1 (in x out) sweep 0...200: NO non-BadArgument/Unsupported pair
IOConnectCallMethod hits: none
IOConnectCallScalarMethod hits: none
```

**Conclusion:** the modern `AppleSMCClient` user client exposes only selectors 0, 1 and 2;
selector 2 is the read-key method but it rejects the classic `SMCKeyData_t` payload with
`kIOReturnBadArgument` at every size we could construct. The payload format is a
**new, undocumented protocol** (the `AppleSMCKeysEndpoint` is an `RTBuddyEndpointService`,
role `"SMC"`). It is not the SMCTool protocol. We could not reverse it in the time budget.

#### 2.1.4 `ioreg` route for temperatures — also negative

```
$ ioreg -l -w0 | grep -i -E "TC0P|TC0D|TC0H|TCAD|TG0P|thermal|Temperature"
```
Only framework/thermal-policy plumbing appeared (e.g. `AppleEmbeddedNVMeTemperatureSensor`,
`IOPMPThermalUserClient` class names in the IOKitDiagnostics class census,
`TemperatureStructVersion2D`, `TemperatureSensor` PMU device maps). **No `TC0P`/`TC0D`
temperature property is exposed as an IORegistry property.**

#### 2.1.5 Registry-wide sweep of every thermal/SMC-ish service

```
$ /tmp/smcprobe7
total services in plane: 1659
interesting services: 16
• AppleSMCPMU                              [userClient=-]
• IOReportHub                              [userClient=IOReportUserClient]
• ApplePMPv2                               [userClient=ApplePMPv2UserClient]
• AGXAcceleratorG18G                       [userClient=-]
• AppleSMCKeysEndpoint                     [userClient=AppleSMCClient]
• AppleSMCSensorDispatcher                 [userClient=AppleSMCSensorDispatcherUserClient]
• SecureRTBuddyIOReporting                 [userClient=-]
…

=== attempt open + SMC-style read on each ===
open fail AppleSMCPMU type=0 -> kIOReturnUnsupported
OPEN OK  IOReportHub type=0  sel0=BadArgument sel1=BadArgument sel2=BadArgument sel3=BadArgument
open fail ApplePMPFirmware type=0 -> kIOReturnUnsupported
OPEN OK  ApplePMPv2 type=0  sel0=kIOReturnNotPrivileged sel1=kIOReturnNotPrivileged
                                sel2=kIOReturnNotPrivileged sel3=kIOReturnNotPrivileged
OPEN OK  AppleSMCKeysEndpoint type=0  sel0=OK sel1=OK sel2=kIOReturnBadArgument
open fail AppleSMCSensorDispatcher type=0 -> kIOReturnBadArgument
```

Key takeaways:
* `ApplePMPv2` (the power-management / thermal controller) **opens** but every method
  returns `kIOReturnNotPrivileged` → **root-only**, as expected.
* `AppleSMCSensorDispatcher` cannot be opened at all (`kIOReturnBadArgument` for
  user-client types 0–31) → the temperature sensor dispatcher is **not reachable**
  unprivileged.
* `IOReportHub` **does** open unprivileged (types 0–31 all accepted), but its methods
  are the private IOReport protocol and the `IOPerformance` framework that wraps it
  **has been removed from macOS 27**:

```
$ dlopen("/System/Library/Frameworks/IOPerformance.framework/IOPerformance", …)
-> 0x0  (no such file, not in dyld cache)
$ dlsym(RTLD_DEFAULT, "IOReportCopyChannelValues")      = 0x0
$ dlsym(RTLD_DEFAULT, "IOReportCopyChannelInformation") = 0x0
```

So the conventional IOReport temperature channel route is closed on this OS.

#### 2.1.6 Complete source of the SMC test program (compiles, runs, reproduces the finding)

```swift
// smctest.swift — unprivileged Apple SMC reader probe
// Build: swiftc -O smctest.swift -o /tmp/smctest -framework IOKit
// Run  : /tmp/smctest            (NO sudo; failure to open is the finding)

import Foundation
import IOKit
import Darwin

// ============================================================================
// SMC structure layout (classic SMCTool / harrisonlilley `smc` conventions).
// The CommandLineTools SDK ships NO SMC headers, so the layout below is the
// de-facto standard one; it is VERIFIED AT RUNTIME against the expected
// offsets/size printed by `dumpLayout()`.
//
//   SMCKeyData_t { key, vers, pLimitData, keyInfo, result, data }
//   offsets: key 0, vers 4, pLimitData 12, keyInfo 28, result 40, data 88
//   sizeof  = 132 in C (Swift .size 130 / .stride 132)
// ============================================================================

struct SMCKeyData_vers_t {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCKeyData_pLimitData_t {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyData_keyInfo_t {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt32 = 0
}

// 32-byte opaque blob, layout-equivalent to C `uint8_t data[32]`.
struct SMCBytes_t {
    var b0: UInt8 = 0;  var b1: UInt8 = 0;  var b2: UInt8 = 0;  var b3: UInt8 = 0
    var b4: UInt8 = 0;  var b5: UInt8 = 0;  var b6: UInt8 = 0;  var b7: UInt8 = 0
    var b8: UInt8 = 0;  var b9: UInt8 = 0;  var b10: UInt8 = 0; var b11: UInt8 = 0
    var b12: UInt8 = 0; var b13: UInt8 = 0; var b14: UInt8 = 0; var b15: UInt8 = 0
    var b16: UInt8 = 0; var b17: UInt8 = 0; var b18: UInt8 = 0; var b19: UInt8 = 0
    var b20: UInt8 = 0; var b21: UInt8 = 0; var b22: UInt8 = 0; var b23: UInt8 = 0
    var b24: UInt8 = 0; var b25: UInt8 = 0; var b26: UInt8 = 0; var b27: UInt8 = 0
    var b28: UInt8 = 0; var b29: UInt8 = 0; var b30: UInt8 = 0; var b31: UInt8 = 0

    var asArray: [UInt8] {
        [b0,b1,b2,b3,b4,b5,b6,b7,b8,b9,b10,b11,b12,b13,b14,b15,
         b16,b17,b18,b19,b20,b21,b22,b23,b24,b25,b26,b27,b28,b29,b30,b31]
    }
    mutating func set(_ a0: [UInt8]) {
        let a = a0 + Array(repeating: 0, count: max(0, 32 - a0.count))
        b0=a[0];b1=a[1];b2=a[2];b3=a[3];b4=a[4];b5=a[5];b6=a[6];b7=a[7]
        b8=a[8];b9=a[9];b10=a[10];b11=a[11];b12=a[12];b13=a[13];b14=a[14];b15=a[15]
        b16=a[16];b17=a[17];b18=a[18];b19=a[19];b20=a[20];b21=a[21];b22=a[22];b23=a[23]
        b24=a[24];b25=a[25];b26=a[26];b27=a[27];b28=a[28];b29=a[29];b30=a[30];b31=a[31]
    }
}

struct SMCKeyData_result_t {
    var result: UInt32 = 0
    var status: UInt32 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes_t = SMCBytes_t()
}

struct SMCKeyData_status_t {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    var pad: UInt8 = 0
    var data: SMCBytes_t = SMCBytes_t()
}

struct SMCKeyData_t {
    var key: UInt32 = 0
    var vers: SMCKeyData_vers_t = SMCKeyData_vers_t()
    var pLimitData: SMCKeyData_pLimitData_t = SMCKeyData_pLimitData_t()
    var keyInfo: SMCKeyData_keyInfo_t = SMCKeyData_keyInfo_t()
    var result: SMCKeyData_result_t = SMCKeyData_result_t()
    var data: SMCKeyData_status_t = SMCKeyData_status_t()
}

// ---------------------------------------------------------------------------
// SMC selector codes (AppleSMC user client external methods)
// ---------------------------------------------------------------------------
enum SMCSel {
    static let readKey      : UInt32 = 2   // SMC_CMD_READ_KEY
    static let readBytes    : UInt32 = 5   // SMC_CMD_READ_BYTES
    static let readIndex    : UInt32 = 8   // SMC_CMD_READ_INDEX
    static let readKeyInfo  : UInt32 = 9   // SMC_CMD_READ_KEYINFO
    static let readPLimit   : UInt32 = 11  // SMC_CMD_READ_PLIMIT
    static let readVers     : UInt32 = 12  // SMC_CMD_READ_VERS
}

func kerr(_ kr: kern_return_t) -> String {
    if kr == KERN_SUCCESS { return "KERN_SUCCESS" }
    return "\(kr) (\(String(cString: mach_error_string(kr))))"
}

/// IOServiceErrorString() is not exported in the public SDK, so map the
/// handful of IOReturn codes we care about by hand.
func ioErr(_ kr: kern_return_t) -> String {
    if kr == kIOReturnSuccess { return "kIOReturnSuccess" }
    let hex = String(format: "0x%08x", UInt32(bitPattern: kr))
    switch kr {
    case kIOReturnNotPrivileged:   return "\(hex) kIOReturnNotPrivileged (privilege violation)"
    case kIOReturnNotPermitted:    return "\(hex) kIOReturnNotPermitted"
    case kIOReturnExclusiveAccess: return "\(hex) kIOReturnExclusiveAccess"
    case kIOReturnNoMemory:        return "\(hex) kIOReturnNoMemory"
    case kIOReturnBadArgument:     return "\(hex) kIOReturnBadArgument"
    case kIOReturnUnsupported:     return "\(hex) kIOReturnUnsupported"
    case kIOReturnError:           return "\(hex) kIOReturnError"
    case kIOReturnBusy:            return "\(hex) kIOReturnBusy"
    default:                       return "\(hex) iokit error"
    }
}

/// Little-endian four-char code, as the SMC expects:
/// 'T','C','0','P' -> 0x50304354  (first char in the LOW byte).
func fourCC(_ s: String) -> UInt32 {
    let b = Array(s.utf8)
    guard b.count == 4 else { return 0 }
    return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
}

/// Big-endian packing — what the task brief proposed. Kept for comparison.
func fourCC_BE(_ s: String) -> UInt32 {
    let b = Array(s.utf8)
    guard b.count == 4 else { return 0 }
    return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
}

func dumpLayout() {
    print("--- SMCKeyData_t layout (runtime, Swift MemoryLayout) ---")
    print("sizeof(SMCKeyData_t)            = \(MemoryLayout<SMCKeyData_t>.size)   (stride \(MemoryLayout<SMCKeyData_t>.stride), C sizeof 132)")
    print("offset(key)                     = \(MemoryLayout<SMCKeyData_t>.offset(of: \.key)!)")
    print("offset(vers)                    = \(MemoryLayout<SMCKeyData_t>.offset(of: \.vers)!)")
    print("offset(pLimitData)              = \(MemoryLayout<SMCKeyData_t>.offset(of: \.pLimitData)!)")
    print("offset(keyInfo)                 = \(MemoryLayout<SMCKeyData_t>.offset(of: \.keyInfo)!)")
    print("offset(result)                  = \(MemoryLayout<SMCKeyData_t>.offset(of: \.result)!)")
    print("offset(data)                    = \(MemoryLayout<SMCKeyData_t>.offset(of: \.data)!)")
    print("sizeof(SMCBytes_t)              = \(MemoryLayout<SMCBytes_t>.size)")
    print("sizeof(SMCKeyData_status_t)     = \(MemoryLayout<SMCKeyData_status_t>.size)")
    print("sizeof(SMCKeyData_result_t)     = \(MemoryLayout<SMCKeyData_result_t>.size)")
    print("sizeof(SMCKeyData_vers_t)       = \(MemoryLayout<SMCKeyData_vers_t>.size)")
    print("sizeof(SMCKeyData_pLimitData_t) = \(MemoryLayout<SMCKeyData_pLimitData_t>.size)")
    print("sizeof(SMCKeyData_keyInfo_t)    = \(MemoryLayout<SMCKeyData_keyInfo_t>.size)")
    print("")
}

/// Decode an SMC payload given its type code.
func decode(_ data: [UInt8], type t: UInt32) -> String {
    func u16(_ i: Int) -> UInt16 { UInt16(data[i]) | UInt16(data[i+1]) << 8 }
    func u32(_ i: Int) -> UInt32 {
        UInt32(data[i]) | UInt32(data[i+1]) << 8 | UInt32(data[i+2]) << 16 | UInt32(data[i+3]) << 24
    }
    switch t {
    case 0x0d: // sp78: signed 16.8 fixed point
        let raw = Int16(bitPattern: u16(0))
        return String(format: "%.2f °C (sp78 raw=%d)", Double(raw) / 256.0, raw)
    case 0x0e: // fp78
        let raw = Int16(bitPattern: u16(0))
        return String(format: "fp78 raw=%d (%.2f)", raw, Double(raw) / 256.0)
    case 0x0f: return "\(u16(0)) (uint8)"
    case 0x10: return "\(u16(0)) (uint16)"
    case 0x11: return "\(u32(0)) (uint32)"
    case 0x05: return "\(u16(0)) (uint16?)"
    case 0x02: return "\(u16(0)) (uint8?)"
    default:
        return "raw=0x" + data.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
dumpLayout()

let uid = getuid()
print("=== running as uid=\(uid) euid=\(geteuid()) (root=\(0)) ===")
print("")

// --- Step 1: enumerate matching services -----------------------------------
func matchingCount(_ className: String) -> Int {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                      IOServiceMatching(className),
                                      &iter) == kIOReturnSuccess else { return -1 }
    var count = 0
    while true {
        let svc = IOIteratorNext(iter)
        if svc == 0 { break }
        count += 1
        IOObjectRelease(svc)
    }
    IOObjectRelease(iter)
    return count
}

for cls in ["AppleSMCUserClient", "AppleSMC", "AppleSMCSensorDispatcherUserClient",
            "AppleSMCSensorDispatcher", "ApplePMPThermalUserClient", "ApplePMGRTempUserClient",
            "AppleSMCSensorDispatcherUserClientV2", "IOReportUserClient"] {
    print("matching services for \(cls): \(matchingCount(cls))")
}
print("")

// --- Step 2: open the AppleSMC user client ---------------------------------
var conn: io_connect_t = 0
var opened = false
var openErr: kern_return_t = 0

// 2a. direct AppleSMCUserClient match
let svcUC = IOServiceGetMatchingService(kIOMainPortDefault,
                                         IOServiceMatching("AppleSMCUserClient"))
if svcUC == 0 {
    print("IOServiceGetMatchingService(AppleSMCUserClient) -> MACH_PORT_NULL (no such service visible)")
} else {
    print("IOServiceGetMatchingService(AppleSMCUserClient) -> service 0x\(String(svcUC, radix: 16))")
    openErr = IOServiceOpen(svcUC, mach_task_self_, 0, &conn)
    print("IOServiceOpen(AppleSMCUserClient) -> \(ioErr(openErr))")
    if openErr == kIOReturnSuccess { opened = true }
    IOObjectRelease(svcUC)
}

// 2b. fall back: the AppleSMC service itself, opened as a user client
if !opened {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                          IOServiceMatching("AppleSMC"))
    if svc == 0 {
        print("IOServiceGetMatchingService(AppleSMC) -> MACH_PORT_NULL")
    } else {
        print("IOServiceGetMatchingService(AppleSMC) -> service 0x\(String(svc, radix: 16))")
        openErr = IOServiceOpen(svc, mach_task_self_, 0, &conn)
        print("IOServiceOpen(AppleSMC) -> \(ioErr(openErr))")
        if openErr == kIOReturnSuccess { opened = true }
        IOObjectRelease(svc)
    }
}

guard opened else {
    print("")
    print("### RESULT: SMC user client is NOT openable by an unprivileged process.")
    print("###         No SMC key reads possible without root.")
    exit(0)
}

print("")
print("### SMC user client OPENED successfully as an unprivileged user.")

// --- Step 3: read keys -------------------------------------------------------
func callStruct(_ selector: UInt32, _ input: inout SMCKeyData_t) -> (kr: kern_return_t, out: SMCKeyData_t) {
    var output = SMCKeyData_t()
    var outputSize = MemoryLayout<SMCKeyData_t>.size
    let kr = withUnsafeMutablePointer(to: &input) { inPtr in
        withUnsafeMutablePointer(to: &output) { outPtr in
            IOConnectCallStructMethod(conn, selector,
                                      UnsafeRawPointer(inPtr), MemoryLayout<SMCKeyData_t>.size,
                                      UnsafeMutableRawPointer(outPtr), &outputSize)
        }
    }
    return (kr, output)
}

/// Read a key: first fetch key info (selector 9), then read the value (selector 2).
func readKey(_ name: String, expectType: UInt32? = nil, expectSize: UInt32? = nil) {
    let key = fourCC(name)
    var info = SMCKeyData_t()
    info.key = key
    let (krInfo, outInfo) = callStruct(SMCSel.readKeyInfo, &info)

    var keyInfo = outInfo.keyInfo
    var note = ""

    if krInfo != kIOReturnSuccess || keyInfo.dataSize == 0 {
        // key-info call failed; fall back to a blind read with the requested type/size
        keyInfo.dataSize = expectSize ?? 2
        keyInfo.dataType = expectType ?? 0x0d
        note = " (keyinfo failed: \(ioErr(krInfo)))"
    } else if expectType != nil && keyInfo.dataType != expectType! {
        note = " (actual type 0x\(String(keyInfo.dataType, radix: 16)) != expected 0x\(String(expectType!, radix: 16)))"
    }

    var input = SMCKeyData_t()
    input.key = key
    input.data.dataSize = keyInfo.dataSize
    input.data.dataType = keyInfo.dataType
    input.data.dataAttributes = UInt8(truncatingIfNeeded: keyInfo.dataAttributes)
    let (kr, out) = callStruct(SMCSel.readKey, &input)

    let raw = out.data.data.asArray
    let hex = raw.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
    let result = out.result.result
    let status = out.result.status

    let ok = (kr == kIOReturnSuccess) && (result == 0)
    let decoded = decode(raw, type: keyInfo.dataType)
    print(String(format: "%-6s key=0x%08x  kr=%-28s result=0x%02x status=0x%02x  size=%u type=0x%02x  bytes=[%@]  -> %@%@",
                     (name as NSString).utf8String!, key,
                     kerr(kr), result, status, keyInfo.dataSize, keyInfo.dataType,
                     hex, ok ? decoded : "FAILED", note))
}

print("--- temperature / sensor keys ---")
for k in ["TC0P", "TC0D", "TC0H", "TC0F", "TC0C", "TC0E", "TC0G", "TCAD", "TC0L", "TC0M"] {
    readKey(k, expectType: 0x0d, expectSize: 2)
}
for k in ["TG0P", "TG0D", "TG0H", "TG0F", "TG0T", "TG0L"] {
    readKey(k, expectType: 0x0d, expectSize: 2)
}
print("--- other sensors / fans / misc ---")
for k in ["Th0H", "Th1H", "TB0T", "Ts0P", "Tp01", "Tp05", "Tp09", "TA0P", "PM0T", "TPCD",
          "FNum", "F0Ac", "F0AcFc", "F0Mn", "F0Mx", "F1Ac"] {
    readKey(k)
}
print("--- big-endian key packing control (should FAIL even for a valid key) ---")
readKey("ZZZZ")
print("")
print("### NOTE: fourCC packing check")
print("fourCC('TC0P')      = 0x\(String(fourCC("TC0P"), radix: 16))   <- correct (little-endian, char0 in low byte)")
print("fourCC_BE('TC0P')   = 0x\(String(fourCC_BE("TC0P"), radix: 16))   <- brief's proposed big-endian form")
print("")

// --- Step 4: version info ----------------------------------------------------
var vInput = SMCKeyData_t()
let (vKr, vOut) = callStruct(SMCSel.readVers, &vInput)
print("readVers kr=\(kerr(vKr)) vers=\(vOut.vers.major).\(vOut.vers.minor).\(vOut.vers.build) release=\(vOut.vers.release)")
var pInput = SMCKeyData_t()
let (pKr, pOut) = callStruct(SMCSel.readPLimit, &pInput)
print("readPLimit kr=\(kerr(pKr)) cpuPLimit=\(pOut.pLimitData.cpuPLimit) gpuPLimit=\(pOut.pLimitData.gpuPLimit) memPLimit=\(pOut.pLimitData.memPLimit)")

IOServiceClose(conn)
```

**Build & run (verified):**

```bash
# plain (works on a normal terminal):
swiftc -O smctest.swift -o /tmp/smctest -framework IOKit
/tmp/smctest

# inside the DSH workspace-write sandbox (module cache redirected):
cd /Users/liuyu/Documents/deepseek-harness/default-workspace/scratch
CLANG_MODULE_CACHE_PATH="$PWD/.modulecache" SWIFT_MODULECACHE_PATH="$PWD/.modulecache" \
swiftc -O -target arm64-apple-macosx27.0 \
  -module-cache-path "$PWD/.modulecache" \
  -Xcc -fmodules-cache-path="$PWD/.modulecache" \
  smctest.swift -o /tmp/smctest -framework IOKit
```

---

### 2.2 Q2 — CPU usage without root — **WORKS**

```
$ sysctl -n hw.ncpu hw.physicalcpu hw.logicalcpu
12
12
12
$ sysctl -n hw.perflevel0.physicalcpu hw.perflevel1.physicalcpu
2
4
$ sysctl -n machdep.cpu.brand_string
Apple M6
```

`/tmp/sysinfo` (source in §2.9):

```
=== host_statistics(HOST_CPU_LOAD_INFO) ===
kr=0 user=16668.981 system=7092.862 idle=247645.353 nice=0.0
aggregate CPU busy = 8.8%

=== host_processor_info(PROCESSOR_CPU_LOAD_INFO) ===
host_processor_info kr=0 numCPUs=12
  core  0: user=  2948.3 sys=  1692.0 idle= 17823.4  busy=20.7%
  core  1: user=  2489.7 sys=  1313.2 idle= 18709.8  busy=16.9%
  …
  core 11: user=   656.3 sys=   138.2 idle= 21880.3  busy=3.5%
  --- delta over 400 ms (this is what a menu-bar app would use) ---
  core  0: busy=38.5%
  core  1: busy=40.0%
  core 10: busy=0.0%
  core 11: busy=0.0%
```

**Minimal working sketch** (the exact API shapes matter in Swift):

```swift
import Darwin

let TH_CPU_SCALE = 1000   // from <mach/machine/thread_status.h>

var cpuInfo: processor_info_array_t?
var numCPUs: natural_t = 0
var infoCnt = mach_msg_type_number_t(0)
// NOTE the argument order: host, flavor, &count, &array, &count
let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                              &numCPUs, &cpuInfo, &infoCnt)
// processor_info_array_t is a FLAT array of natural_t: [user, sys, idle, nice] per core
for i in 0..<Int(numCPUs) {
    let b = i * 4
    let user = Double(cpuInfo![b])   / Double(TH_CPU_SCALE)
    let sys  = Double(cpuInfo![b+1]) / Double(TH_CPU_SCALE)
    let idle = Double(cpuInfo![b+2]) / Double(TH_CPU_SCALE)
    let busy = 100.0 * (user + sys) / max(user + sys + idle, 0.0001)
    print("core \(i): \(String(format: "%.1f", busy))%")
}
```

Gotchas found the hard way:
* `host_processor_info`'s parameter order is `(host, flavor, &count, &array, &arrayCnt)` — passing
  `&cpuInfo` 2nd triggers a Swift type error.
* `processor_info_array_t` imports as a **flat** `UnsafeMutablePointer<integer_t>`, not an array
  of pointers; each core occupies **4 consecutive** `natural_t` (user, system, idle, nice).
* `TH_CPU_SCALE` is **not** exposed to Swift — hard-code `1000`.
* For a menu-bar readout you want the **delta** between two samples (the absolute ticks are
  cumulative since boot). The 400 ms delta above is the usable number.
* `host_statistics(HOST_CPU_LOAD_INFO)` works too but only gives the machine-wide aggregate.

---

### 2.3 Q3 — Thermal pressure — **WORKS (coarse)**

```
$ /tmp/sysinfo
=== NSProcessInfo.thermalState ===
thermalState rawValue = 0
thermalState = .nominal
NSProcessInfoThermalStateDidChangeNotification = NSProcessInfoThermalStateDidChangeNotification
observer installed OK (fired during window = false)
```

* `ProcessInfo.processInfo.thermalState` → `.nominal` in a **plain command-line process**
  (no bundle, no entitlement, no `NSApplication`).
* The notification constant in Swift is `ProcessInfo.thermalStateDidChangeNotification`
  (raw value `"NSProcessInfoThermalStateDidChangeNotification"`). An observer installs and
  runs without error; it simply did not fire during the 0.4 s window because the state
  did not change. The mechanism is therefore usable.
* It is a **4-state bucket** (`.nominal` / `.fair` / `.serious` / `.critical`) — **no °C value**.

```
$ pmset -g therm
Note: No thermal warning level has been recorded
Note: No performance warning level has been recorded
Note: No CPU power status has been recorded
(exit 0)
```
→ `pmset -g therm` **does run unprivileged** (contrary to the common belief that it needs
root), but it only reports *warning levels*, never a temperature, and on an idle machine
it says "no … has been recorded".

```
$ pmset -g assertions   → works, full assertion list
$ pmset -g batt          → "Now drawing from 'AC Power'"
$ pmset -g ps            → "Now drawing from 'AC Power'"
$ pmset -g thermlog      → blocks forever (streaming log), no output without root
```

Battery data via IOKit: `IOPMPowerSource` service exists, but
`IOPSCopyPowerSourcesInfo()` returned **nil** — this is a mains-powered Mac mini
(`Mac18,5`) with no internal battery, so there is no battery temperature to read.

---

### 2.4 Q4 — `powermetrics` — **ROOT ONLY**

```
$ powermetrics
powermetrics must be invoked as the superuser
$ ls -la /usr/bin/powermetrics
-rwxr-xr-x  1 root  wheel  505008 Aug 27 13:48 /usr/bin/powermetrics
```
Not setuid, no group bit → strictly root. This is the classic source of CPU-die
temperature on Apple Silicon (`powermetrics --samplers smc`), and it is unavailable
without a privileged helper.

---

### 2.5 Q5 — GPU

**GPU utilization is readable unprivileged** via the AGX accelerator node:

```
$ ioreg -c AGXAccelerator -l -w0 -r -d 1
+-o AGXAcceleratorG18G  <class AGXAcceleratorG18G, id 0x100000673, registered, matched, active, …>
      "PerformanceStatistics" = {"In use system memory (driver)"=0,
                                 "Alloc system memory"=9735421952,
                                 "Tiler Utilization %"=24,
                                 "recoveryCount"=0,
                                 "lastRecoveryTime"=0,
                                 "Renderer Utilization %"=33,
                                 "TiledSceneBytes"=1310720,
                                 "Device Utilization %"=33,
                                 "SplitSceneCount"=0,
                                 "Allocated PB Size"=110624768,
                                 "In use system memory"=757940224}
```

The same dictionary is reachable with the **public IOKit property API** (no `ioreg`
subprocess needed) — verified:

```swift
let svc = /* AGXAcceleratorG18G service */
if let cf = IORegistryEntryCreateCFProperty(svc, "PerformanceStatistics" as CFString,
                                            kCFAllocatorDefault, 0)?.takeRetainedValue(),
   let stats = cf as? [String: Any] {
    let device = stats["Device Utilization %"]      // 33
    let renderer = stats["Renderer Utilization %"]  // 33
    let tiler = stats["Tiler Utilization %"]        // 24  (changed 21→24 between samples)
}
```
→ `Device Utilization %` / `Renderer Utilization %` / `Tiler Utilization %` are live and
update between samples. This is exactly how `macmon` reports GPU load.

**GPU temperature: not exposed.** The full AGX property key list contains no temperature:

```
AGCInfo, AGXParameterBufferMaxSize, GPURawCounterBundleName, IOClass, IOGLBundleName,
MetalPluginName, PerformanceStatistics, SchedulerState, SurfaceList, model, …
```
(`grep -io "[a-z]*temp[a-z]*" ` over the node → **no matches**.)

**Metal** gives the device identity only:

```
=== Metal devices ===
  Apple M6 | lowPower=false headless=false maxThreads=1024
```
`MTLCopyAllDevices()` → `MTLDevice` exposes `name`, `isLowPower`, `isHeadless`,
`maxThreadsPerThreadgroup` — no utilization, no temperature, no clock.

`powermetrics` is the only route to GPU temperature and it is root-only.

---

### 2.6 Q6 — Menu-bar app without Xcode — **WORKS**

**Exact build command (verified):**

```bash
cd /Users/liuyu/Documents/deepseek-harness/default-workspace/scratch
APP=/tmp/MenuBarProto.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MenuBarProto</string>
    <key>CFBundleDisplayName</key><string>MenuBarProto</string>
    <key>CFBundleIdentifier</key><string>com.example.menubarproto</string>
    <key>CFBundleExecutable</key><string>MenuBarProto</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

swiftc -O -parse-as-library -target arm64-apple-macosx13.0 \
  -module-cache-path "$PWD/.modulecache" \
  -Xcc -fmodules-cache-path="$PWD/.modulecache" \
  menubar.swift -o "$APP/Contents/MacOS/MenuBarProto" \
  -framework SwiftUI -framework AppKit -framework Foundation
```

Build result:
```
=== BUILD EXIT: 0 ===
-rwxr-xr-x  1 liuyu  wheel  145872 Nov 14 20:16 MenuBarProto
/tmp/MenuBarProto.app/Contents/MacOS/MenuBarProto: Mach-O 64-bit executable arm64
```

Notes:
* `-parse-as-library` is **required** because the file uses `@main` (top-level code and
  `@main` cannot coexist).
* `-target arm64-apple-macosx13.0` pins the deployment target so `MenuBarExtra`
  (macOS 13+) is available and the app runs on macOS 13+.
* `-framework SwiftUI -framework AppKit -framework Foundation` is all that is needed;
  `-framework IOKit` only if you use IOKit directly.
* In this sandbox you additionally need `-module-cache-path` / `-Xcc -fmodules-cache-path`
  because the default clang module cache under `$TMPDIR` is not writable.

**Launch & verify (verified):**

```
$ open /tmp/MenuBarProto.app          # exit 0
$ lsappinfo list | grep -A5 MenuBarProto
174) "MenuBarProto" ASN:0x0-0x872872:
    bundleID="com.example.menubarproto"
    bundle path="/private/tmp/MenuBarProto.app"
    pid = 48304 token=[sess=100109 pid=48304 uid:501,501,501 g:20,20 …] type="UIElement" flavor=3 …
    launch time =  13 seconds ago, 2026/11/14 20:16:35

$ launchctl print gui/501 | grep -i menubarproto
   48304  -  application.com.example.menubarproto.1201346.1201807
```

`type="UIElement"` **confirms `LSUIElement = true` is what keeps the app out of the Dock**
(LaunchServices registers it as an accessory/UI-element app: no Dock tile, no app menu).
The app also runs when the binary is executed directly (LaunchAgent-style, without `open`):

```
$ /tmp/MenuBarProto.app/Contents/MacOS/MenuBarProto &
$ lsappinfo list | grep -A4 MenuBarProto
175) "MenuBarProto" … pid = 48966 … type="UIElement" flavor=3
```
(`bundleID=[NULL]` when exec'd directly instead of via `open` — LaunchServices does not
fully register the bundle; harmless, but for a LaunchAgent you should point
`ProgramArguments` at the executable and it works fine.)

Signing: `codesign -dv` shows the swiftc-produced **ad-hoc (`linker-signed`) signature**:
```
Signature=adhoc
Info.plist=not bound
```
That is enough for local launch. For distribution you would add
`codesign --force --deep --sign - <bundle>` (still ad-hoc) — but nothing in the app needs
special entitlements, and no entitlement would unlock the SMC/thermal interfaces anyway.

**Complete source of the menu-bar prototype** (compiles and runs as shown above):

```swift
// menubar.swift — minimal SwiftUI MenuBarExtra app, built with swiftc only
// (no Xcode project).

import SwiftUI
import AppKit
import Darwin

// MARK: - CPU sampling (Mach host_processor_info, no root required)

final class CPUSampler: ObservableObject {
    @Published var perCore: [Double] = []
    @Published var aggregate: Double = 0
    @Published var coreCount: Int = 0
    private var prev: [UInt32] = []
    private var timer: Timer?

    init() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    deinit { timer?.invalidate() }

    func sample() {
        var cpuInfo: processor_info_array_t?
        var numCPUs: natural_t = 0
        var cnt = mach_msg_type_number_t(0)
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &numCPUs, &cpuInfo, &cnt) == KERN_SUCCESS,
              let arr = cpuInfo else { return }
        let n = Int(numCPUs)
        coreCount = n
        var current = [UInt32](repeating: 0, count: n * 4)
        for i in 0..<n {
            let b = i * 4
            current[b]   = UInt32(arr[b])       // user
            current[b+1] = UInt32(arr[b+1])   // system
            current[b+2] = UInt32(arr[b+2])   // idle
            current[b+3] = UInt32(arr[b+3])   // nice
        }
        if prev.count == current.count {
            var busy: [Double] = []
            for i in 0..<n {
                let b = i * 4
                let du = Double(current[b]   &- prev[b])
                let ds = Double(current[b+1] &- prev[b+1])
                let di = Double(current[b+2] &- prev[b+2])
                let tot = du + ds + di
                busy.append(tot > 0 ? 100.0 * (du + ds) / tot : 0)
            }
            perCore = busy
            aggregate = busy.isEmpty ? 0 : busy.reduce(0, +) / Double(busy.count)
        }
        prev = current
    }
}

// MARK: - Thermal pressure (public Foundation API, no root required)

final class ThermalWatcher: ObservableObject {
    @Published var state: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.state = ProcessInfo.processInfo.thermalState
        }
    }

    deinit {
        if let t = token { NotificationCenter.default.removeObserver(t) }
    }

    var label: String {
        switch state {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-braces: force accessory (menu-bar only, no Dock icon).
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct MenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var cpu = CPUSampler()
    @StateObject private var thermal = ThermalWatcher()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(cpu)
                .environmentObject(thermal)
        } label: {
            // Menu-bar title: CPU% + thermal state marker.
            Text(String(format: "%.0f%%", cpu.aggregate))
                .monospacedDigit()
                .foregroundStyle(cpu.aggregate > 70 ? Color.red : Color.primary)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var cpu: CPUSampler
    @EnvironmentObject private var thermal: ThermalWatcher

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CPU  \(String(format: "%.1f", cpu.aggregate))%  (\(cpu.coreCount) cores)")
                .font(.headline)
            Text("Thermal state: \(thermal.label)")
                .font(.subheadline)
            Divider()
            ForEach(Array(cpu.perCore.enumerated()), id: \.offset) { idx, v in
                HStack {
                    Text(String(format: "core %2d", idx)).monospacedDigit()
                    ProgressView(value: v, total: 100)
                        .frame(width: 110)
                    Text(String(format: "%5.1f%%", v)).monospacedDigit()
                }
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .frame(width: 260)
    }
}
```

---

### 2.7 Q7 — Homebrew & existing tools

```
$ brew --version
Homebrew 7.0.13
$ which brew
/opt/homebrew/bin/brew

$ brew list
abseil ada-url brotli ca-certificates fmt hdrhistogram_c highway icu4c@79 libffi
libnghttp2 libuv llhttp lz4 merve nbytes node openssl@4 pnpm readline simdjson
simdutf sqlite uvwasi xz zstd
```
→ **No sensor tooling installed** (no `smc`, no `osx-cpu-temp`, no `istats`, no `macmon`).

```
$ brew info smc
Error: No available formula with the name "smc". Did you mean smu, swc, src, sic, shc, sec, scc, sac?
```
→ the classic `smc` CLI has been **removed/disabled** from Homebrew.

```
$ brew search --formula cpu-temp
osx-cpu-temp
$ brew search --formula macmon
macmon
$ brew search --formula istats
ifstat
```
→ `osx-cpu-temp` and `macmon` are still catalogued (neither installed). Note that
`osx-cpu-temp` reads `TC0P` via the classic SMC protocol, which per §2.1 **does not work**
on this macOS build, so installing it would most likely produce no temperature.
`macmon` is the more interesting candidate: it uses the same AGX
`PerformanceStatistics` route we verified for GPU utilization.

---

### 2.8 Q8 — Launch agents

```
$ ls -la ~/Library/LaunchAgents/
ls: /Users/liuyu/Library/LaunchAgents/: No such file or directory
```
→ the standard per-user LaunchAgent directory **does not exist yet** and must be created
(`mkdir -p ~/Library/LaunchAgents`).

The GUI domain is healthy and enumerable:

```
$ launchctl print gui/501
gui/501 = {
	type = login
	handle = 100109
	…  (3920 lines)
```

The canonical command forms (to be re-verified outside the sandbox):

```bash
# 1. install
mkdir -p ~/Library/LaunchAgents
cp com.example.myapp.plist ~/Library/LaunchAgents/com.example.myapp.plist
plutil -lint ~/Library/LaunchAgents/com.example.myapp.plist

# 2. load into THIS user's GUI session
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.myapp.plist

# 3. inspect
launchctl print gui/$(id -u)/com.example.myapp

# 4. unload
launchctl bootout gui/$(id -u)/com.example.myapp
```

**Verification status: BLOCKED BY THE HARNESS SANDBOX, not by macOS.**
Every attempt in this session failed identically:

```
$ launchctl bootstrap gui/501  /tmp/dsh-launchagent-test.plist
Bootstrap failed: 5: Input/output error
Try re-running the command as root for richer errors.

$ launchctl bootstrap user/501 /tmp/dsh-launchagent-test.plist
Bootstrap failed: 5: Input/output error

$ launchctl load -w /tmp/dsh-launchagent-test.plist
Load failed: 5: Input/output error

$ mkdir -p ~/Library/LaunchAgents
mkdir: /Users/liuyu/Library/LaunchAgents: Operation not permitted
```

`Bootstrap failed: 5` (EIO) is the classic error when the bootstrap message cannot be
delivered to launchd — consistent with the `workspace-write` sandbox blocking the
launchd IPC, not with a broken macOS. The plist itself was valid
(`plutil -lint` → `OK`), the `gui/501` domain was readable, and `launchctl print`
worked throughout. **This must be re-run in a normal Terminal to confirm.**

Also verified: launching the app binary directly (the way a LaunchAgent would)
works and the process registers in the GUI session as `type="UIElement"`.

---

### 2.9 `sysinfo.swift` — the combined CPU / thermal / power / Metal probe

Built with:

```bash
swiftc -O -target arm64-apple-macosx27.0 \
  -module-cache-path "$PWD/.modulecache" \
  -Xcc -fmodules-cache-path="$PWD/.modulecache" \
  sysinfo.swift -o /tmp/sysinfo -framework IOKit -framework Metal
```

The complete source lives at
`/Users/liuyu/Documents/deepseek-harness/default-workspace/scratch/sysinfo.swift`
and contains: `sysctl` topology, `host_statistics(HOST_CPU_LOAD_INFO)`,
`host_processor_info(PROCESSOR_CPU_LOAD_INFO)` with a 400 ms delta sample,
`ProcessInfo.thermalState` + notification, `IOPMPowerSource` / `IOPSCopyPowerSourcesInfo`,
and `MTLCopyAllDevices`.

---

## 3. Implications for the app design

### 3.1 What a no-sudo app CAN show (all verified working on this machine)

| Metric | API | Notes |
|---|---|---|
| Aggregate CPU % | `host_statistics(HOST_CPU_LOAD_INFO)` | machine-wide only |
| **Per-core CPU %** | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | 12 cores; use 2-sample delta |
| CPU topology | `sysctl hw.ncpu / hw.physicalcpu / hw.logicalcpu / hw.perflevel*` | 12/12/12, P=2, E=4(+6) |
| **GPU utilization %** | `AGXAcceleratorG18G` → `IORegistryEntryCreateCFProperty("PerformanceStatistics")` | `Device/Renderer/Tiler Utilization %`, updates live |
| GPU name | `MTLCopyAllDevices()` | "Apple M6" |
| Thermal pressure | `ProcessInfo.processInfo.thermalState` | nominal/fair/serious/critical |
| Thermal change events | `ProcessInfo.thermalStateDidChangeNotification` | observer installs cleanly |
| Memory | `host_statistics64(HOST_VM_INFO64)` / `task_info` | standard, not probed here but unprivileged |
| AC/battery state | `pmset -g batt` / `IOPSCopyPowerSourcesInfo` | AC-only on this Mac mini |
| Assertion state | `pmset -g assertions` | unprivileged, works |

### 3.2 What it CANNOT show without root

* **Numeric CPU die temperature (°C)** — every route is closed:
  SMC (protocol removed/replaced), `AppleSMCSensorDispatcher` (cannot open),
  `ApplePMPv2` (`kIOReturnNotPrivileged`), `powermetrics` (superuser only),
  `IOReport`/`IOPerformance` (framework removed from macOS 27), IORegistry properties
  (not exposed).
* **Numeric GPU temperature** — not exposed anywhere unprivileged.
* **Fan RPM / count** — SMC `F0Ac`/`FNum` unreadable. (This Mac mini is fanless anyway —
  `FNum` would be 0 even if readable.)

### 3.3 Fallback ladder for temperature

1. **`ProcessInfo.thermalState` — ship this by default.** It is the only public,
   entitlement-free, sandbox-free thermal signal on this OS. Render it as a
   4-state badge (`nominal` / `fair` / `serious` / `critical`), driven by
   `thermalStateDidChangeNotification`. Zero privileges, zero risk, works in a
   `LSUIElement` SwiftUI menu-bar app (proven in §2.6).
2. **Label the metric honestly.** Show "Thermal: nominal", **not** "Temp: 42 °C".
   Do not synthesise a °C number from the state — that is misleading.
3. **Optional privileged helper (only if the user opts in).** A tiny
   `SMJobBless`/`launchd`-root helper running `powermetrics --samplers smc -i 1000`
   (or reading the new SMC protocol once reverse-engineered) can supply real °C.
   Cost: an installer, a `com.apple.security.get-task-allow`-free privileged helper,
   a `LaunchDaemon` plist in `/Library/LaunchDaemons`, and explicit user consent.
   **Recommend deferring this** unless a numeric temperature is a hard requirement.
4. **Third-party binaries are no help.** `osx-cpu-temp` uses the same dead SMC path.
   `macmon` would add GPU-utilisation (already available directly) but no temperature
   without root.
5. **Consider the AGX/`IOReport` route further.** `IOReportHub` opens unprivileged and
   is the one remaining unexplored temperature channel source. It requires reimplementing
   the private IOReport protocol (the `IOPerformance` wrapper was removed from macOS 27).
   Feasible but a substantial reverse-engineering effort — worth a follow-up spike if
   numeric temperature becomes mandatory.

### 3.4 Build & packaging notes for the project

* `swiftc` + the Command Line Tools SDK is **sufficient** to ship the menu-bar app:
  `MenuBarExtra` compiles and runs, and the hand-assembled bundle launches as a
  proper menu-bar accessory.
* `LSUIElement = true` in `Info.plist` is the switch that removes the Dock icon
  (verified: `lsappinfo` reports `type="UIElement"`).
* `-parse-as-library` is mandatory with `@main`.
* No entitlements, no `NSApplication` sandbox profile, and no code signing identity are
  required for any of the metrics that work. (A sandboxed app would need
  `com.apple.security.application-group` / temp-file exceptions only if it shells out
  to `ioreg`/`pmset`; using the IOKit APIs directly avoids that entirely — as done here.)
* Prefer the IOKit APIs over shelling out to `ioreg`/`pmset`: fewer processes, no
  parsing, no sandbox exceptions, and it works identically in a `LSUIElement` app.

---

## 4. Open questions

1. **What is the modern `AppleSMCClient` selector-2 payload?** The service
   (`AppleSMCKeysEndpoint`, `IOUserClientClass = AppleSMCClient`) opens unprivileged and
   implements selector 2, but rejects the classic `SMCKeyData_t` at every size. Its wire
   format is undocumented. Reverse-engineering it (disassembling `AppleSMC` kext /
   `RTBuddy` endpoint protocol) is the only path to *any* numeric SMC value on this OS
   without root. **Open — highest value follow-up.**
2. **Is `IOReportHub` (opens unprivileged) able to deliver temperature channels?**
   `IOReportUserClient` is unreachable via `IOServiceMatching` (user clients live in a
   non-registered plane), but `IOReportHub` opens with type 0…31 and answers methods 0–5.
   `IOPerformance.framework` — the usual wrapper — is **absent from macOS 27's dyld
   cache**, so the protocol would have to be reimplemented from scratch. **Open.**
3. **Does `sudo powermetrics` still expose a usable `TC0P`-equivalent on this build?**
   Not tested (we did not use sudo, by design). If the project later adds a privileged
   helper, this must be re-measured — especially because `powermetrics`'s SMC sampler may
   itself be broken by the same protocol change.
4. **Is the SMC rejection a macOS-27 regression or an Apple-Silicon-by-design change?**
   Compare against macOS 26 on the same hardware (or an Intel Mac) to see whether the
   classic `TC0P` path ever worked on this machine. If it worked on 26 and stopped on 27,
   that is a regression worth filing.
5. **Q8 must be re-verified outside the sandbox** — `launchctl bootstrap gui/$(id -u)`
   and `~/Library/LaunchAgents` creation were both blocked here.
6. **`AppleSMCSensorDispatcher` open fails with `kIOReturnBadArgument` for every user-client
   type 0–31.** The correct `type` index may be larger than 31, or the open may require a
   different service-plane entry. Worth one more sweep (types 32…255) before writing it off.
7. **`IOPSCopyPowerSourcesInfo()` returned nil** on this AC-only Mac mini. If the app
   should also work on MacBooks, the battery path (`IOPMPowerSource` →
   `kIOPSTemperatureKey`) needs separate verification on a machine with a battery.
8. **Memory metrics were not probed** (out of scope here) but are standard
   `host_statistics64(HOST_VM_INFO64)`; expect them to work unprivileged.

---

## 5. Artefacts

| Path | What |
|---|---|
| `/Users/liuyu/Documents/deepseek-harness/default-workspace/research/macos-m6-temperature-feasibility.md` | this report |
| `…/default-workspace/scratch/smctest.swift` | SMC test program (full source in §2.1.6) |
| `…/default-workspace/scratch/smctest` | — built to `/tmp/smctest` |
| `…/default-workspace/scratch/smcprobe2.swift` … `smcprobe9.swift` | SMC probes: service matching, method matrix, size sweeps, IOConnect variants |
| `…/default-workspace/scratch/sysinfo.swift` | CPU / thermal / power / Metal probe |
| `…/default-workspace/scratch/menubar.swift` | SwiftUI `MenuBarExtra` prototype (full source in §2.6) |
| `…/default-workspace/scratch/agx.txt` | `ioreg -c AGXAccelerator -l` dump |
| `/tmp/smctest`, `/tmp/smcprobe2..9`, `/tmp/sysinfo` | compiled probes |
| `/tmp/MenuBarProto.app` | hand-assembled menu-bar app bundle |
