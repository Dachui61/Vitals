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
