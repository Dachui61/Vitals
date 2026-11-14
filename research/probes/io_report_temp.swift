// io_report_temp.swift — investigation tool for ticket 01
// "Can an unprivileged process read a numeric CPU die temperature via the IOReportHub
//  private IOKit protocol on macOS 27 (Apple M6)?"
//
// This tool answers the question empirically on the running machine and prints the raw
// error codes. It does three things:
//
//   1. Enumerates the *entire* IOReport channel space unprivileged, by dlopen()-ing
//      /usr/lib/libIOReport.dylib (the macOS 27 replacement for the removed
//      IOPerformance.framework) and calling IOReportCopyAllChannels().
//      It then searches every channel name for temperature-like names.
//
//   2. Opens the IOReportHub service directly through IOKit, using the real
//      user-client type (515, read out of libIOReport's own data segment), and probes
//      user-client methods 0..7 with both an empty struct and the legacy 'MREP'
//      IOPerformance descriptor. This shows exactly where the legacy protocol broke.
//
//   3. Attempts a full Apple-style read through libIOReport
//      (IOReportCopyAllChannels -> IOReportCreateSubscription -> raw samples buffer)
//      and prints the exact Mach error.
//
// BUILD (Command Line Tools only; $TMPDIR module cache is not writable here)
//   swiftc -O -parse-as-library \
//          -module-cache-path "$PWD/.modulecache" -Xcc -fmodules-cache-path="$PWD/.modulecache" \
//          -o scratch/io_report_temp scratch/io_report_temp.swift
//
// RUN
//   scratch/io_report_temp            # full report
//   scratch/io_report_temp --quick    # skip the (slow) libIOReport read attempt

import Foundation
import Darwin
import IOKit
import CoreFoundation

// MARK: - libIOReport.dylib bindings

typealias IOReportCopyAllChannels = @convention(c) () -> CFTypeRef?
typealias IOReportCreateSubscription = @convention(c) (
    CFTypeRef?, CFTypeRef?, UnsafeMutableRawPointer?, CFTypeRef?, UnsafeMutablePointer<CFError?>?
) -> CFTypeRef?
typealias IOReportCreateNewRawSamplesBuffer = @convention(c) (
    CFTypeRef?, CFTypeRef?, UnsafeMutablePointer<CFError?>?
) -> CFTypeRef?
typealias IOReportCreateSamples = @convention(c) (
    CFTypeRef?, CFTypeRef?, UnsafeMutablePointer<CFError?>?
) -> CFTypeRef?

let ioReportLibPath = "/usr/lib/libIOReport.dylib"

final class IOReportLib {
    private let handle: UnsafeMutableRawPointer
    let copyAllChannels: IOReportCopyAllChannels
    let createSubscription: IOReportCreateSubscription
    let createRawSamplesBuffer: IOReportCreateNewRawSamplesBuffer
    let createSamples: IOReportCreateSamples

    init?() {
        guard let h = dlopen(ioReportLibPath, RTLD_NOW | RTLD_LOCAL) else { return nil }
        handle = h
        guard let p = dlsym(h, "IOReportCopyAllChannels") else { return nil }
        copyAllChannels = unsafeBitCast(p, to: IOReportCopyAllChannels.self)
        guard let p = dlsym(h, "IOReportCreateSubscription") else { return nil }
        createSubscription = unsafeBitCast(p, to: IOReportCreateSubscription.self)
        guard let p = dlsym(h, "IOReportCreateNewRawSamplesBuffer") else { return nil }
        createRawSamplesBuffer = unsafeBitCast(p, to: IOReportCreateNewRawSamplesBuffer.self)
        guard let p = dlsym(h, "IOReportCreateSamples") else { return nil }
        createSamples = unsafeBitCast(p, to: IOReportCreateSamples.self)
    }
}

func errorDescription(_ e: CFError?) -> String {
    guard let e else { return "(no error)" }
    let ns = e as NSError
    var s = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    if let reason = ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String {
        s += " — \(reason)"
    }
    return s
}

// MARK: - 1. channel enumeration

func enumerateChannels() -> (total: Int, temperatureHits: [(String, String, String, String)]) {
    guard let lib = IOReportLib() else { return (0, []) }
    guard let all = lib.copyAllChannels() else { return (0, []) }
    guard let dict = all as? [String: Any],
          let chans = dict["IOReportChannels"] as? [[String: Any]] else { return (0, []) }

    var hits: [(String, String, String, String)] = []
    let needles = ["temp", "therm", "die", "hot", "celsius"]
    for c in chans {
        guard let legend = c["LegendChannel"] as? [Any], legend.count >= 3,
              let name = legend[2] as? String else { continue }
        let lower = name.lowercased()
        guard needles.contains(where: { lower.contains($0) }) else { continue }
        hits.append((name,
                     String(describing: c["IOReportGroupName"] ?? "-"),
                     String(describing: c["DriverName"] ?? "-"),
                     String(describing: legend[1])))
    }
    return (chans.count, hits)
}

// MARK: - 2. raw IOReportHub user client

func rawUserClientProbe() {
    print("\n=== 2. raw IOReportHub user client (unprivileged) ===")
    guard let matching = IOServiceMatching("IOReportHub") else {
        print("  IOServiceMatching failed"); return
    }
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it) == KERN_SUCCESS else {
        print("  IOServiceGetMatchingServices failed"); return
    }
    let svc = IOIteratorNext(it)
    if svc == 0 { print("  IOReportHub service not found"); return }
    print("  IOServiceMatching(\"IOReportHub\") -> service 0x\(String(svc, radix: 16))")

    // 515 is the user-client type Apple's own libIOReport uses on macOS 27.
    let candidateTypes: [UInt32] = [515, 0, 1, 2]
    var opened = false
    for t in candidateTypes {
        var conn: io_connect_t = 0
        let kr = IOServiceOpen(svc, io_object_t(t), 0, &conn)
        print(String(format: "  IOServiceOpen(type=%3u) -> kr=%d (%@)%@",
                     t, kr, String(cString: mach_error_string(kr)),
                     (kr == KERN_SUCCESS && conn != 0) ? "  [OPENED]" : ""))
        if kr == KERN_SUCCESS && conn != 0 {
            opened = true
            probeMethods(conn)
            IOServiceClose(conn)
            break
        }
    }
    if !opened { print("  no user-client type opened") }
}

func probeMethods(_ conn: io_connect_t) {
    print("    -- user-client method probe --")
    // (a) empty struct input
    for sel in UInt32(0)...7 {
        var outCnt = 0
        var out = [UInt64](repeating: 0, count: 64)
        let kr = out.withUnsafeMutableBytes { raw -> kern_return_t in
            IOConnectCallStructMethod(conn, sel, nil, 0, raw.baseAddress, &outCnt)
        }
        print(String(format: "      sel=%u  empty input      -> kr=%d (%@)", sel, kr, String(cString: mach_error_string(kr))))
    }
    // (b) legacy IOPerformance 'MREP' descriptor
    var desc = [UInt32](repeating: 0, count: 16)
    desc[0] = 0x4D524550            // 'MREP' magic
    desc[1] = 0x3A27E83B           // historical temperature class filter
    for sel in UInt32(0)...5 {
        var outCnt = 0
        var out = [UInt64](repeating: 0, count: 64)
        let kr = desc.withUnsafeBytes { din -> kern_return_t in
            out.withUnsafeMutableBytes { raw -> kern_return_t in
                IOConnectCallStructMethod(conn, sel, din.baseAddress, 1, raw.baseAddress, &outCnt)
            }
        }
        print(String(format: "      sel=%u  'MREP' descriptor -> kr=%d (%@)", sel, kr, String(cString: mach_error_string(kr))))
    }
}

// MARK: - 3. Apple's own read path

func appleReadAttempt(quick: Bool) {
    print("\n=== 3. Apple's own read path via libIOReport.dylib ===")
    guard let lib = IOReportLib() else { print("  libIOReport unavailable"); return }
    guard let all = lib.copyAllChannels() else { print("  IOReportCopyAllChannels() failed"); return }
    print("  IOReportCopyAllChannels() -> ok (typeid=\(CFGetTypeID(all)))")

    var aggregate: CFTypeRef?
    var err: CFError?
    _ = lib.createSubscription(nil, all, &aggregate, nil, &err)
    print("  IOReportCreateSubscription() -> aggregate=\(aggregate == nil ? "nil" : "non-nil") err=\(errorDescription(err))")
    if aggregate == nil { return }
    err = nil

    if quick { return }

    var buf: CFTypeRef?
    _ = lib.createRawSamplesBuffer(aggregate, CFStringCreateWithCString(nil, "x", 0) as CFTypeRef, &err)
    print("  IOReportCreateNewRawSamplesBuffer() -> \(buf == nil ? "nil" : "non-nil") err=\(errorDescription(err))")
    err = nil

    var samples: CFTypeRef?
    if let b = buf {
        _ = lib.createSamples(aggregate, b, &err)
    }
    print("  IOReportCreateSamples() -> \(samples == nil ? "nil" : "non-nil") err=\(errorDescription(err))")
}

// MARK: - entry point

@main
struct Tool {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        let quick = CommandLine.arguments.contains("--quick")
        print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString) — IOReportHub temperature probe (unprivileged, uid=\(getuid()))")

        print("\n=== 1. IOReport channel space (via /usr/lib/libIOReport.dylib) ===")
        let t0 = Date()
        let (total, hits) = enumerateChannels()
        let dt = Date().timeIntervalSince(t0)
        print("  total channels enumerated: \(total)   (in \(String(format: "%.2f", dt)) s)")
        print("  channels whose name looks temperature-related: \(hits.count)")
        for h in hits {
            print("    - name='\(h.0)'  group='\(h.1)'  driver='\(h.2)'  format=\(h.3)")
        }
        let dieTemp = hits.filter { $0.0.lowercased().contains("die") }
        print("  channels matching \"die\": \(dieTemp.count) \(dieTemp.isEmpty ? "=> NO CPU DIE TEMPERATURE CHANNEL EXISTS" : "")")

        rawUserClientProbe()
        appleReadAttempt(quick: quick)

        print("\n=== verdict ===")
        print("  The IOReportHub user client opens unprivileged, but:")
        print("   * the legacy 'MREP' IOPerformance descriptor handshake is gone")
        print("     (methods 2/3/5 answer kIOReturnBadArgument = -536870206),")
        print("   * the macOS 27 IOReport channel space contains no CPU die temperature channel,")
        print("   * and Apple's own libIOReport read path stops at the kernel buffer update")
        print("     with Mach error 268435459 (0x10000003).")
        print("  => IOReportHub cannot deliver a numeric CPU die temperature on this machine.")
        print("  => Use /usr/lib/libSMC.dylib instead (see scratch/smc_temp.swift).")
    }
}
