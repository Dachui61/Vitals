# Ticket 02 — `powermetrics` SMC sampler: output format & CPU temperature extraction

**Project:** Vitals (macOS menu-bar + floating-window CPU load / temperature monitor)
**Machine:** macOS 27.0 (build 26A425), Apple M6 Mac mini (Mac18,5), arm64, 12 cores (2P + 4E + 6Le)
**Date:** 2026-11-14
**Author:** research subagent (delegated from `session-8c5a074a-4229-4b96-80ca-64f22b873e7d`)

---

## Verdict

**No — root `powermetrics` cannot give Vitals a CPU die temperature on macOS 27.** The `smc` sampler does not exist in macOS 27's `powermetrics`: `--samplers smc` is rejected during argument parsing with `powermetrics: unrecognized sampler: smc` and exit code **64**, *before* the root check, so it fails identically for root and non-root. The `arm64e` slice of the binary (the one that actually runs on this M6) contains **zero** bytes matching `smc` and **zero** matching `temperatur` — the SMC sampler and every die-temperature print were deleted from the Apple Silicon build. Even a root helper would have nothing to parse, so **a root-`powermetrics` privileged helper must not be built for temperature on this platform**; use `NSProcessInfo.thermalState` (unprivileged, 4-level pressure) and/or the IOReportHub path owned by the sibling ticket.

---

## Evidence

**Root status: NOT AVAILABLE.** `sudo -n true` returned exit **126** with `bash: /usr/bin/sudo: Operation not permitted` — the session sandbox blocks `sudo` entirely (the user *is* in group `admin` and would have passwordless-capable sudo in a normal Terminal). No password prompt was attempted. Everything below is therefore **binary/primary-source evidence plus unprivileged execution**, not a root capture.

### 1. The `smc` sampler is rejected — this is the decisive observation

`powermetrics` validates sampler names *before* it checks for root, so this error is observable without privileges:

```
$ /usr/bin/powermetrics --samplers smc -i 1000
powermetrics: unrecognized sampler: smc        # on STDERR
$ echo $?
64
```

Stdout is empty (`powermetrics: unrecognized sampler: smc` goes to **stderr**, not stdout — relevant for the privileged helper's error capture).

Same for the ticket's suggested combination and for `thermal_pressure`:

| Command | stderr | exit |
|---|---|---|
| `powermetrics --samplers smc -i 1000` | `powermetrics: unrecognized sampler: smc` | **64** |
| `powermetrics --samplers thermal_pressure -i 1000` | `powermetrics: unrecognized sampler: thermal_pressure` | **64** |
| `powermetrics --samplers smc,thermal_pressure,cpu_power,gpu_power` | `powermetrics: unrecognized sampler: smc` | **64** |
| `powermetrics --samplers thermal -i 1000` | `powermetrics must be invoked as the superuser` | **1** |
| `powermetrics` (no args) | `powermetrics must be invoked as the superuser` | **1** |

Note the ordering consequence: an **unknown sampler name** yields `unrecognized sampler: …`/64, a **known** sampler name without root yields `must be invoked as the superuser`/1. These two are cleanly distinguishable, which is useful UX copy.

### 2. The shipped `--help` sampler list (macOS 27.0) contains no `smc`

From `/usr/bin/powermetrics --help` (captured verbatim to `scratch/pm_help.txt`):

```
The following samplers are supported by --samplers:

    tasks             per task cpu usage and wakeup stats
    battery           battery and backlight info
    network           network usage info
    disk              disk usage info
    interrupts        interrupt distribution
    cpu_power         cpu power and frequency info
    thermal           thermal pressure notifications
    sfi               selective forced idle information
    gpu_power         gpu power and frequency info
    ane_power         dedicated rail ane power and frequency info

and the following sampler groups are supported by --samplers:

    all           tasks,battery,network,disk,interrupts,cpu_power,thermal,sfi,gpu_power,ane_power
    default       tasks,battery,network,disk,interrupts,cpu_power,gpu_power,ane_power
```

`smc` is absent. `thermal_pressure` is also absent as a *sampler* name — the correct name is **`thermal`** (`thermal_pressure` is only a *plist key* inside the `thermal` sampler).

### 3. Binary-level proof: SMC and temperature strings are gone from the arm64e slice

`/usr/bin/powermetrics` is a fat Mach-O with three slices:

```
$ file /usr/bin/powermetrics
/usr/bin/powermetrics: Mach-O universal binary with 3 architectures:
  [x86_64:Mach-O 64-bit executable x86_64]
  [arm64e:Mach-O 64-bit executable arm64e]
  [arm64e.x1:Mach-O 64-bit executable arm64e.x1]
```

Per-slice string extraction (`lipo -thin` → `strings`, plus raw byte grep):

| needle | `arm64e` (runs on M6) | `arm64e.x1` | `x86_64` (legacy Intel) |
|---|---|---|---|
| `smc` (byte-level, case-sensitive) | **0** | **0** | 7 |
| `SMC` (byte-level, case-sensitive) | **0** | **0** | 7 |
| `temperatur` (byte-level) | **0** | **0** | 2 |
| registered sampler names | `gpu_power, thermal, ane_power, interrupts, tasks, cpu_power, battery, network, devices, disk, sfi` | — | `thermal, interrupts, tasks, cpu_power, battery, network, devices, gpu_power, disk` |

**In the arm64e slice there is no `smc` string at all and no `temperatur` string at all.** The SMC sampler source and the die-temperature print statements were deleted from the Apple Silicon build of `powermetrics` (files `smc.c`, `smc_context_init`, `failed to match to AppleSMC`, `unable to get smc values` survive only in the x86_64 slice).

Registered sampler names present in the arm64e slice (exact-match `strings -n 3`), for completeness: `gpu_power`, `thermal`, `ane_power`, `interrupts`, `tasks`, `cpu_power`, `battery`, `network`, `devices`, `disk`, `sfi`. (`--samplers sfi` is accepted — it reaches the root check.) **No `smc`.**

> **Methodology note.** `strings` defaults to a 4-character minimum, which would silently hide a bare 3-character `"smc"` literal. Every short-name claim above was therefore re-verified two ways: (a) `strings -a -n 3`, and (b) a **byte-level** `grep -aoc` over the raw slice, which is immune to length filtering. Byte-level result: `smc` = **0** in `pm_arm64e`, `SMC` = **0** in `pm_arm64e`; `smc` = 7 and `SMC` = 7 in `pm_x86_64`, resolving to the tokens `AppleSMC`, `SMC`, `smc`, `smc-version`, `smc.c`, `smc_context_init`, `smc_prochot`, `smc_version`. The whole-binary byte-level count for `smc` is 7 — **all of them in the x86_64 slice**.

### 4. Rosetta does not rescue the `smc` sampler

Rosetta 2 **is** installed and working on this machine:

```
$ pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto
version: 1.0.0.0.1787810290
$ ls -ld /Library/Apple/usr/libexec/oah      # present
$ arch -x86_64 ./rosetta_check_x86
proc_translated=1
```

So the x86_64 slice *can* be executed here — and it *still* rejects the sampler:

```
$ arch -x86_64 /usr/bin/powermetrics --samplers smc -i 1000
powermetrics: unrecognized sampler: smc
$ arch -x86_64 /usr/bin/powermetrics
powermetrics must be invoked as the superuser
```

Conclusion: the **sampler registry** has no `"smc"` entry in *any* slice of the macOS 27 binary. Only the legacy SMC *rendering code* survives in x86_64 (reached via `--show-extra-power-info` on Intel Macs). The `man` page's "SMC" section is stale documentation.

### 5. The man page is stale — do not trust it

`man powermetrics` still contains an "SMC" section:

> **SMC** — The smc sampler displays information supplied by the System Management Controller. On supported platforms, this includes fan speed and information from various temperature sensors. These are instantaneous values taken at the end of the sample window…

…but the page footer reads **`Darwin 5/1/12`** — it is the OS X Lion-era (2012) man page, never updated. It contradicts the shipped binary's `--help` and the actual behaviour. **This man page must not be used as a spec.**

### 6. What the arm64e build *can* say about heat: pressure only, never °C

From the arm64e slice strings:

```
**** Thermal pressure ****
Current pressure level: %s
<key>thermal_pressure</key><string>%s</string>
```

Level literals present in the arm64e slice (exact case): **`Nominal`**, **`Moderate`**. (`Serious` / `Critical` / `Fair` do not appear as literals anywhere in the binary — they are presumably produced at runtime by a system framework. Partially unverified; a root capture would settle it.)

`--show-extra-power-info` on arm64e yields **power**, not heat:

```
CPU Power: %0.0f mW
GPU Power: %0.0f mW
ANE Power: %0.0f mW
```

Full arm64e plist-key inventory (machine-readable field names) contains **no temperature key whatsoever**. The nearest fields are:

```
thermal_pressure   (string)   cpu_power, gpu_power, ane_power, combined_power
cpu_energy, gpu_energy, ane_energy   freq, freq_hz   cpu_plimit-like plimit_* (x86_64 only)
```

### 7. The legacy Intel SMC format — for reference only (it does not run here)

The x86_64 slice retains the only surviving SMC implementation in macOS 27's `powermetrics`. Its **text** format strings, verbatim from the binary:

```
**** SMC sensors ****
CPU Thermal level: %llu
 (simulated:%llu)
GPU Thermal level: %llu
IO Thermal level: %llu
Fan: %g rpm
CPU die temperature: %.2f C%s
GPU die temperature: %.2f C%s
CPU Plimit: %.2f
GPU Plimit (Int): %.2f
GPU2 Plimit (Ext1): %.2f
GPU3 Plimit (Ext2): %.2f
Number of prochots: %llu
CPU asserting prochot
SMC asserting prochot
(SMC is currently in monitor mode, no data available)
```
plus `SMC version: %s`.

Its **plist** form (this is the machine-readable mapping that a parser should have targeted):

```xml
<key>smc</key>
<dict>
  <key>cpu_thermal_level</key><integer>%llu</integer>
  <key>simulated_cpu_thermal_level</key><integer>%llu</integer>
  <key>gpu_thermal_level</key><integer>%llu</integer>
  <key>simulated_gpu_thermal_level</key><integer>%llu</integer>
  <key>io_thermal_level</key><integer>%llu</integer>
  <key>simulated_io_thermal_level</key><integer>%llu</integer>
  <key>fan</key><real>%g</real>
  <key>cpu_die</key><real>%.2f</real>
  <key>cpu_die_power_target</key><real>%d</real>
  <key>cpu_die_fan_target</key><real>%d</real>
  <key>gpu_die</key><real>%.2f</real>
  <key>gpu_die_power_target</key><real>%d</real>
  <key>gpu_die_fan_target</key><real>%d</real>
  <key>cpu_plimit</key><real>%.2f</real>
  <key>gpu_plimit</key><real>%.2f</real>
  <key>gpu_plimit2</key><real>%.2f</real>
  <key>gpu_plimit3</key><real>%.2f</real>
  <key>num_prochots</key><integer>%llu</integer>
  <key>cpu_prochot</key><%s/>
  <key>smc_prochot</key><%s/>
</dict>
```

Two corrections to the ticket's working assumptions:

- **The format is NOT `"TC0P = 42.5 C"`.** `powermetrics` never printed raw SMC key names. A regex scan for raw key names over the *whole* binary (`^T[A-Z][0-9][A-Z]?$`, `TC0P`, `TA0P`, `TG0P`, `Th\dH`) returns **0 hits**. The curated format is `CPU die temperature: 45.50 C`.
- **The unit is plain °C as a 2-decimal float**, space before `C`, plus an optional trailing `%s` suffix. The only adjacent literal candidates for that suffix are `" (power)"` and `" (fan)"` (used elsewhere in the same slice for prochot reasons) — i.e. it most likely denotes *why* the die is hot. **UNVERIFIED** without a root capture on Intel hardware.

### 8. The classic SMC user-client path is dead on this machine (confirms the ticket's premise)

The SMC IOKit service is still registered, but under a different class:

```
$ ioreg -c AppleSMC -r -d 1
+-o AppleSMCKeysEndpoint  <class AppleSMCKeysEndpoint, id 0x1000007f0, ...>
    "IOUserClientClass" = "AppleSMCClient"
    "IONameMatch" = "SMCEndpoint1"
    "IOPersonalityPublisher" = "com.apple.driver.AppleSMC"
```

The sibling agent's exhaustive probe (`scratch/smcprobe9.swift`, compiled and executed here as uid 501) connects to `AppleSMCKeysEndpoint` but **every** read path fails:

```
uid=501; connected to AppleSMCKeysEndpoint (AppleSMCClient)

selector 2, step-1 (in x out) sweep 0...200: NO non-BadArgument/Unsupported pair
IOConnectCallMethod hits: none
IOConnectCallScalarMethod hits: none
```

i.e. the `AppleSMCKeyData_t` user-client protocol returns `kIOReturnBadArgument`/`kIOReturnUnsupported` for every selector and size combination. So even forcing the x86_64 slice through Rosetta would land in `unable to get smc values` / `(SMC is currently in monitor mode, no data available)`.

### 9. Unprivileged heat sources that *do* work on this box

| Source | Works as uid 501? | Output |
|---|---|---|
| `NSProcessInfo.thermalState` | ✅ yes | `.nominal` (rawValue 0); `ProcessInfo.thermalStateDidChangeNotification` installs cleanly |
| `pmset -g therm` | ✅ yes | `Note: No thermal warning level has been recorded` / `No performance warning level has been recorded` / `No CPU power status has been recorded` — levels only, empty on a healthy idle Mac mini |
| `ioreg` | ✅ yes | `AppleSMCKeysEndpoint` exists but exposes **no** temperature properties |
| `/usr/libexec/thermalmonitord` | ✅ runs | **No CLI output at all** (exit 0, prints nothing). Its symbols include `getTemperatureFromSMCForKey:`, `temperatureForKey:`, `thermalPressureLevel`, `thermalState`, `sendVirtualTemp:temperature:` — i.e. the system thermal daemon *does* read temperatures internally (via a privileged/internal path, not the dead user client), but it is not a queryable data source |
| IOReportHub | service present | out of scope — sibling ticket |

---

## Parser design

### A. Primary recommendation: do not write a powermetrics temperature parser

There is no temperature line to anchor to. Any parser written against `powermetrics --samplers smc` would be dead code on macOS 27.

### B. If Vitals wants a *level* (no root, no subprocess) — recommended

Use `ProcessInfo.processInfo.thermalState` directly in-process, mapped as:

| `NSProcessInfo.ThermalState` | rawValue | Suggested Vitals label |
|---|---|---|
| `.nominal` | 0 | Nominal |
| `.fair` | 1 | Fair |
| `.serious` | 2 | Serious |
| `.critical` | 3 | Critical |

Drive updates from `ProcessInfo.thermalStateDidChangeNotification` (event-driven, zero polling cost) with a 1 Hz poll only as a reconciliation fallback. No privileged helper, no subprocess, no regex.

### C. If Vitals insists on a root helper anyway — scope it to *power*, not temperature

The supported root invocation is:

```
sudo powermetrics --samplers cpu_power --show-extra-power-info -f plist -i 1000
```

**Parse the plist, never the text.** `-f plist` emits NUL-separated property lists (per `--help`: "machine-readable property list, NUL-separated"), so each sample is a self-delimiting blob and you never have to guess line boundaries:

```swift
// Split on NUL; each chunk is one complete plist sample.
let chunks = raw.split(separator: 0, omittingEmptySubsequences: true)
for chunk in chunks {
    let dict = try PropertyListSerialization.propertyList(
        from: Data(chunk), format: nil) as! [String: Any]
    let mW = dict["cpu_power"] as? Double   // arm64e key
    let combined = dict["combined_power"] as? Double
}
```

Field mapping for the arm64e plist (from the key inventory — **all verified present in the binary**):

| plist key | meaning | unit |
|---|---|---|
| `cpu_power` | CPU package power | mW |
| `gpu_power` | GPU power | mW |
| `ane_power` | ANE power | mW |
| `combined_power` | SoC combined power | mW |
| `cpu_energy` / `gpu_energy` / `ane_energy` | energy over the sample window | — |
| `thermal_pressure` | pressure level string (`Nominal`, `Moderate`, …) | enum |
| `freq` / `freq_hz` | per-cluster frequency | Hz |

### D. Legacy-Intel parser (reference implementation, for Intel Macs / Rosetta only)

If Vitals ever ships on Intel macOS, the CPU die temperature line **is** anchorable by regex — the anchor is the label, not the line number:

```
^\s*CPU die temperature:\s*(-?\d+(?:\.\d+)?)\s*C(?<suffix>.*)$
```

Key→sensor mapping for the legacy `smc` plist dict:

| plist key | sensor | unit | format |
|---|---|---|---|
| `cpu_die` | **CPU die temperature** | °C | `<real>%.2f` → e.g. `45.50` |
| `gpu_die` | GPU die temperature | °C | `<real>%.2f` |
| `fan` | fan speed | rpm | `<real>%g` |
| `cpu_thermal_level` | CPU thermal pressure level | 0–4 | `<integer>` |
| `gpu_thermal_level` | GPU thermal pressure level | 0–4 | `<integer>` |
| `io_thermal_level` | IO thermal pressure level | 0–4 | `<integer>` |
| `num_prochots` | prochot count | — | `<integer>` |
| `cpu_prochot` / `smc_prochot` | prochot reason (`power` / `fan`) | — | `<string>` |

Text-mode equivalents (legacy Intel only):

| line | sensor | unit |
|---|---|---|
| `CPU die temperature: 45.50 C` | CPU die | °C, 2 decimals |
| `GPU die temperature: 46.50 C` | GPU die | °C, 2 decimals |
| `Fan: 1200 rpm` | fan | rpm |
| `CPU Thermal level: 0` | CPU pressure | 0–4 |

Note the legacy `cpu_die` is a **die** temperature in °C — *not* 0.1 °C fixed point, and *not* per-core. There is no per-core/per-cluster CPU temperature anywhere in `powermetrics`.

### E. Caching / smoothing policy for a 1 Hz sampler

Applies to whichever source ends up feeding the number:

1. **Sample at 1 Hz** (`-i 1000`), but **publish at 1 Hz** — do not publish faster than you sample.
2. **Exponential moving average**, `ema = 0.7·ema + 0.3·sample`, seeded with the first sample. Rationale: a die sensor sampled at 1 Hz jitters ±0.5 °C; an EMA with α=0.3 gives a ≈2 s time constant, enough to kill jitter without hiding a real ramp.
3. **Reject implausible samples** before smoothing: drop values outside `15…125 °C` (or whatever band the chosen sensor supports). A single bad read must not poison the EMA.
4. **Staleness budget**: if the last good sample is older than **5 s**, stop displaying a number and show the "unavailable" state instead of a frozen value. Track `lastGoodSampleAt` explicitly.
5. **Do not average across a state change.** On a pressure-level transition (nominal → fair), reset the EMA to the new sample rather than blending levels.
6. **Cache the last N (≈10) raw samples** so the UI can show a sparkline without re-querying, and so a transient dropout doesn't blank the display.
7. **Round only at display time** — keep full precision internally; the legacy plist gives 2 decimals, the EMA should not be re-rounded until rendering.

---

## Operational notes

**Do not build the privileged helper for temperature.** There is no temperature field on this platform. If Vitals ships a helper anyway, scope it to power/frequency.

**Invocation (if a helper is built for power):**

```
powermetrics --samplers cpu_power --show-extra-power-info -f plist -i 1000 -n -1
```

| Flag | Meaning (from `--help`) |
|---|---|
| `-i, --sample-rate <N>` | sample every N **milliseconds**; default 5000 |
| `-n, --sample-count <N>` | number of periodic samples; `--help` says **default −1 = infinite**, the stale man page says `0 = infinite`. **Use `-n -1` explicitly** (the `--help` text reflects the shipped binary) and don't rely on the default. |
| `-f, --format <format>` | `text` (default) or **`plist`** (machine-readable, NUL-separated) |
| `-b, --buffer-size <size>` | output buffer size (`0`=none, `1`=line) |
| `-o, --output-file <file>` | write to a file instead of stdout |
| `--show-usage-summary` | print a final usage summary on exit |
| `--show-extra-power-info` | extra power info (arm64e: CPU/GPU/ANE mW) |

**Termination & lifecycle:**
- `SIGINT` / `SIGTERM` / `SIGHUP` → *stop sampling and exit* (graceful).
- `SIGINFO` → *take an immediate sample* (useful for a "refresh now" affordance).
- `SIGIO` → *flush any buffered output*.
- `powermetrics` never exits on its own with `-n -1`; the helper must own the lifetime and restart it.

**Restart policy:**
- Watch for exit codes: **64** = bad arguments (never retry — it is a permanent config error), **1** = not root (permanent), any other = treat as transient, back off exponentially (1 s → 30 s cap) and restart.
- If the helper is running as root via a launchd daemon, the "must be invoked as the superuser" error should be impossible; if it appears, the helper lost privilege (e.g. a `sudo`-based wrapper misconfigured) — surface it as an install/permission problem, not a transient error.
- **Do not** treat a mid-stream `powermetrics` exit as "no data": drain the pipe, parse whatever complete NUL-terminated plists arrived, and keep the last good value until the staleness budget (5 s) expires.

**Cost:**
- `powermetrics` is a heavy process: it walks the task table, samples interrupts, etc. The `--samplers cpu_power` + `--show-extra-power-info` configuration is the lightest useful root configuration; `--samplers all` (or the `default` group, which includes `tasks`) is dramatically more expensive and should never be used for a 1 Hz background monitor.
- `thermal` alone is the lightest sampler (a single pressure-level read) but still requires root and still yields no °C.
- The no-root alternative (`NSProcessInfo.thermalState` + notification) has effectively **zero** cost — no process, no timer, no IPC. This is the reason it should be the primary path.

**Trust/UX boundary:** `powermetrics`' own `--help` warns that its average power values are estimates and must not be used for cross-device comparison. Surface power numbers as estimates.

**UX copy (exact strings, verified):**
- Not running as root → `powermetrics must be invoked as the superuser` (stderr, exit 1).
- Bad sampler name → `powermetrics: unrecognized sampler: <name>` (stderr, exit 64).
- Suggested Vitals wording: *"Temperature requires a privileged helper on macOS 27 and is unavailable; showing thermal pressure instead."*

---

## User-run commands

Root was unavailable in the agent sandbox (sudo blocked). If you want to confirm the findings with real root, run these in a normal Terminal:

**1. Confirm the `smc` sampler does not exist even as root (the headline finding):**

```bash
sudo powermetrics --samplers smc -i 1000 -n 1; echo "exit=$?"
# expected: powermetrics: unrecognized sampler: smc
#          exit=64
```

**2. Confirm `thermal_pressure` is not a sampler name either:**

```bash
sudo powermetrics --samplers thermal_pressure -i 1000 -n 1; echo "exit=$?"
# expected: powermetrics: unrecognized sampler: thermal_pressure   exit=64
```

**3. Capture the only heat signal powermetrics can give on Apple Silicon (text):**

```bash
sudo powermetrics --samplers thermal -i 1000 -n 5 > /tmp/pm_thermal.txt 2>&1
cat /tmp/pm_thermal.txt
# expected shape:
#   **** Thermal pressure ****
#   Current pressure level: Nominal
```

**4. Capture the machine-readable form (what a helper should actually consume):**

```bash
sudo powermetrics --samplers thermal -f plist -i 1000 -n 5 > /tmp/pm_thermal.plist 2>&1
# each sample is a NUL-terminated plist; inspect with:
python3 - <<'PY'
data = open('/tmp/pm_thermal.plist','rb').read()
for i, chunk in enumerate(data.split(b'\x00')):
    if chunk.strip():
        print(i, chunk.decode('utf-8','replace')[:400])
PY
```

**5. Capture the power/extra-power info (the only numeric thermal-adjacent root data on arm64e):**

```bash
sudo powermetrics --samplers cpu_power --show-extra-power-info -f plist -i 1000 -n 5 > /tmp/pm_power.plist 2>&1
strings /tmp/pm_power.plist | head -40
```

**6. Settle the pressure-level vocabulary (which level words exist on this build):**

```bash
sudo powermetrics --samplers thermal -i 1000 -n 3 2>&1 | grep -i 'pressure level'
# also exercise the levels by loading the CPU, e.g.:
#   yes > /dev/null & sleep 60; sudo powermetrics --samplers thermal -i 1000 -n 3
```

**7. Optional — test whether the legacy x86_64 slice can render SMC under Rosetta as root (expected to fail, but worth one data point):**

```bash
sudo arch -x86_64 /usr/bin/powermetrics --show-extra-power-info -i 1000 -n 1 2>&1 | head -40
# expected: no "**** SMC sensors ****" block, or
#           "(SMC is currently in monitor mode, no data available)" /
#           "unable to get smc values"
```

**8. Capture the unprivileged ground truth for the app's own reading (no root needed):**

```bash
cat > /tmp/vitals_thermal.swift <<'SWIFT'
import Foundation
let p = ProcessInfo.processInfo
print("thermalState rawValue = \(p.thermalState.rawValue)")
switch p.thermalState {
case .nominal:  print("Nominal")
case .fair:     print("Fair")
case .serious:  print("Serious")
case .critical: print("Critical")
@unknown default: print("unknown")
}
print("observation:", NotificationCenter.default.addObserver(
    forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in })
SWIFT
swiftc -O -module-cache-path "$PWD/.modulecache" -Xcc -fmodules-cache-path="$PWD/.modulecache" \
  /tmp/vitals_thermal.swift -o /tmp/vitals_thermal && /tmp/vitals_thermal
```

---

## Open questions

1. **Does the arm64e `thermal` sampler ever emit level words beyond `Nominal` / `Moderate`?** The literals `Serious`, `Critical`, `Fair` do not appear in the binary; they may come from a system framework at runtime. Needs a root capture under load (command 6 above).
2. **What is the `%s` suffix in the legacy `CPU die temperature: %.2f C%s`?** Most likely `" (power)"` / `" (fan)"` (the only adjacent literals), but this is Intel-only code and unreachable on this machine. Would need an Intel host to confirm; irrelevant for macOS 27 Apple Silicon.
3. **Can the x86_64 slice under Rosetta as root still render the SMC block?** Expected to fail at `unable to get smc values` because the user-client reads are dead (§8), but not directly observable without root (command 7).
4. **Is `NSProcessInfo.thermalState` in 1:1 correspondence with `powermetrics`' `Current pressure level`?** Both come from the same thermal daemon but via different APIs; the literal vocabularies differ (`Nominal`/`Moderate` vs `.nominal`/`.fair`/`.serious`/`.critical`). Worth a side-by-side comparison under synthetic load so Vitals can map its own enum onto powermetrics's vocabulary if it ever displays both.
5. **Numeric CPU °C at all on macOS 27?** Entirely dependent on the IOReportHub sibling ticket. If IOReportHub also lacks a die-temperature channel on Apple Silicon, Vitals should ship the pressure level as the primary thermal signal and drop the °C display (or source °C from a third-party helper). This should be settled before any UI copy promises "°C".
6. **Does `thermalmonitord` expose anything queryable** (e.g. an XPC client or a debug mode) that a third-party app could read without root? Its symbol set shows it reads SMC temperatures internally; whether that is reachable outside the daemon is unknown and would need root/reverse engineering.

---

## Sources

| Claim | Source |
|---|---|
| `smc` sampler rejected, exit 64, stderr text | live execution of `/usr/bin/powermetrics` (captured in `scratch/pm_unpriv.txt`, `scratch/pm_help.txt`) |
| Sampler list for macOS 27 | `/usr/bin/powermetrics --help` → `scratch/pm_help.txt` |
| No `smc` / no `temperatur` in arm64e slice | `lipo -thin` + `strings` + byte-level `grep` over `/usr/bin/powermetrics` (slices saved to `scratch/pm_arm64e`, `scratch/pm_x86_64`) |
| Legacy SMC text/plist format | `strings` over the `x86_64` slice of `/usr/bin/powermetrics` |
| Man page is stale (Darwin 5/1/12) | `man powermetrics` → `/tmp/pm_man.txt` |
| Rosetta present and functional | `pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto`; `sysctl.proc_translated` = 1 |
| SMC user-client reads dead | `scratch/smcprobe9.swift` (built & run as uid 501) |
| `AppleSMCKeysEndpoint` / `AppleSMCClient` present | `ioreg -c AppleSMC -r -d 1` → `scratch/ioreg_applesmc.txt` |
| `thermalState` works unprivileged | `scratch/sysinfo.swift` (built & run) → `.nominal`, rawValue 0 |
| `pmset -g therm` levels only, empty | live execution |
| `thermalmonitord` reads SMC temps but has no CLI output | `strings /usr/libexec/thermalmonitord`; live execution (exit 0, no output) |
| IOReportHub service present, legend captured | `scratch/agx.txt`; sibling probe `scratch/iohub_temp.swift` |
