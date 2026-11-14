// smc_keys.swift — enumerate + read + stress-test every SMC key on this Apple Silicon Mac,
// unprivileged, via /usr/lib/libSMC.dylib.
//
// WHY THIS EXISTS
// ---------------
// Ticket 23: "which SMC key is the CPU die temperature on Apple M6?"
// Key names are undocumented and chip-specific, so guessing is not acceptable.
// libSMC.dylib exports SMCGetKeyFromIndex(), which lets us enumerate the *entire*
// key space instead of guessing prefixes. For every key we then fetch the SMC
// key info (dataType / dataAttributes) and the numeric value, and finally run
// CPU-load and GPU-load experiments to see which sensors track which block.
//
// BUILD (Command Line Tools only; $TMPDIR module cache is not writable here)
//   swiftc -O -parse-as-library \
//          -module-cache-path "$PWD/.modulecache" -Xcc -fmodules-cache-path="$PWD/.modulecache" \
//          -o scratch/smc_keys scratch/smc_keys.swift
//
// RUN
//   scratch/smc_keys enumerate                       # every key + info + value (TSV)
//   scratch/smc_keys enumerate --max 4096
//   scratch/smc_keys info TH0x Tp05                  # raw key-info blob for specific keys
//   scratch/smc_keys watch TH0x Tp05 --seconds 10    # 1 Hz sampling
//   scratch/smc_keys watch --temps --seconds 30 --load cpu  --out cputest.tsv
//   scratch/smc_keys watch --temps --seconds 30 --load gpu   --out gputest.tsv
//   scratch/smc_keys watch --temps --seconds 30 --load gpu   --cores 0-5
//
// The same file provides SMCClient (dlopen/dlsym + key packing), so the project
// can reuse it verbatim.

import Foundation
import Darwin
import Metal
import MetalPerformanceShaders
import CoreImage
import CoreGraphics

// MARK: - libSMC.dylib bindings

typealias SMCOpenDefaultService = @convention(c) () -> UnsafeMutableRawPointer?
typealias SMCReadKeyAsNumeric = @convention(c) (
    UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<Double>?
) -> Int32
typealias SMCGetKeyInfo = @convention(c) (
    UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?
) -> Int32
/// SMCGetKeyFromIndex(connection, keyIndex, SMCKey_t *key) -> SMCError
typealias SMCGetKeyFromIndex = @convention(c) (
    UnsafeMutableRawPointer?, UInt32, UnsafeMutablePointer<UInt32>?
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
    private let keyInfoFn: SMCGetKeyInfo
    private let keyFromIndexFn: SMCGetKeyFromIndex
    let connection: UnsafeMutableRawPointer

    init() throws {
        guard let h = dlopen("/usr/lib/libSMC.dylib", RTLD_NOW | RTLD_LOCAL) else {
            throw SMCError.dlopenFailed(String(cString: dlerror()))
        }
        handle = h
        func sym<T>(_ name: String, _ type: T.Type) -> T {
            guard let p = dlsym(h, name) else { fatalError("missing symbol \(name)") }
            return unsafeBitCast(p, to: type)
        }
        openDefault = sym("SMCOpenConnectionWithDefaultService", SMCOpenDefaultService.self)
        readKey = sym("SMCReadKeyAsNumeric", SMCReadKeyAsNumeric.self)
        keyInfoFn = sym("SMCGetKeyInfo", SMCGetKeyInfo.self)
        keyFromIndexFn = sym("SMCGetKeyFromIndex", SMCGetKeyFromIndex.self)

        guard let conn = openDefault() else { throw SMCError.openFailed }
        connection = conn
    }

    /// Apple packs a 4-char SMC key big-endian: 'T','C','0','P' -> 0x54433050.
    static func key(_ s: String) -> UInt32 {
        let b = Array(s.utf8)
        precondition(b.count == 4)
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    static func string(_ k: UInt32) -> String {
        let b = [UInt8(k >> 24 & 0xff), UInt8(k >> 16 & 0xff), UInt8(k >> 8 & 0xff), UInt8(k & 0xff)]
        return String(decoding: b, as: UTF8.self)
    }

    /// Numeric value of a key, or nil if absent/unreadable.
    func read(_ keyString: String) -> Double? {
        var numeric = [UInt8](repeating: 0, count: 24)
        var value: Double = 0
        let rc = numeric.withUnsafeMutableBytes { raw -> Int32 in
            readKey(connection, SMCClient.key(keyString), raw.baseAddress, &value)
        }
        return rc == 0 ? value : nil
    }

    /// Raw SMC key-info blob (SMCKeyData_t layout) for diagnostics.
    func infoBytes(_ keyString: String) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: 64)
        let rc = buf.withUnsafeMutableBytes { raw -> Int32 in
            keyInfoFn(connection, SMCClient.key(keyString), raw.baseAddress)
        }
        return rc == 0 ? Array(buf) : nil
    }

    /// Enumerate the SMC key space. Returns [(index, keyUInt32)].
    func enumerateKeys(max: Int = 65536) -> [(index: Int, key: UInt32)] {
        var out: [(index: Int, key: UInt32)] = []
        var k: UInt32 = 0
        var misses = 0
        for i in 0..<max {
            let rc = keyFromIndexFn(connection, UInt32(i), &k)
            if rc == 0 {
                out.append((i, k))
                misses = 0
            } else {
                misses += 1
                // rc == -3 (0xfd) => index out of range; -4 (0xfc) => invalid key.
                if rc == -3 { break }
                if misses > 64 { break }
            }
        }
        return out
    }
}

// MARK: - SMC key info decoding

/// Decoded pieces of the SMCGetKeyInfo() result blob.
struct SMCKeyInfo {
    var raw: [UInt8]
    /// dataType lives at offset 20 (UInt32 LE).
    var dataType: UInt32 {
        UInt32(raw[20]) | UInt32(raw[21]) << 8 | UInt32(raw[22]) << 16 | UInt32(raw[23]) << 24
    }
    /// dataAttributes at offset 24.
    var dataAttributes: UInt8 { raw[24] }
    /// version major/minor at offset 4/5 (0x85 = 133 on this build).
    var version: (UInt8, UInt8) { (raw[4], raw[5]) }
    /// payload length at offset 14 (UInt16 LE).
    var pLimitSize: UInt16 { UInt16(raw[14]) | UInt16(raw[15]) << 8 }
}

/// Human-readable names for the SMC "dataType" field (Apple SMC numeric types).
let smcDataTypeNames: [UInt32: String] = [
    0x00: "SP78", 0x01: "FLT", 0x02: "FP1F", 0x03: "FP2F", 0x04: "FP4F",
    0x05: "FPE2", 0x06: "UINT8", 0x07: "UINT16", 0x08: "UINT32", 0x09: "UINT64",
    0x0a: "DEC1", 0x0b: "CHAR", 0x0c: "DATA", 0x0d: "HEX",
]

// MARK: - CPU load generation

// <mach/thread_policy.h> is not exposed to Swift; declare the bits we need.
private let THREAD_AFFINITY_POLICY: thread_policy_flavor_t = 4
private let THREAD_AFFINITY_POLICY_COUNT = 1
private struct thread_affinity_policy_info_t { var affinity_tag: Int32 }

/// Pin the calling thread to one logical CPU (works for threads we own).
func pinCurrentThread(toCore core: Int) -> Bool {
    var info = thread_affinity_policy_info_t(affinity_tag: Int32(core))
    let r = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: integer_t.self, capacity: 1) { q in
            thread_policy_set(pthread_mach_thread_np(pthread_self()),
                              thread_policy_flavor_t(THREAD_AFFINITY_POLICY),
                              q, mach_msg_type_number_t(THREAD_AFFINITY_POLICY_COUNT))
        }
    }
    return r == KERN_SUCCESS
}

/// QoS classes used to steer the scheduler onto a specific core cluster on
/// Apple Silicon (userInteractive -> P/S cores, background -> E cores).
/// NOTE: THREAD_AFFINITY_POLICY is NOT supported on this platform
/// (thread_policy_set returns 46 = KERN_NOT_SUPPORTED), so QoS class is the
/// only lever available for cluster-selective load.
enum LoadQoS: String {
    case userInteractive, defaultQoS, background
    var raw: Int32 {
        switch self {
        case .userInteractive: return 0x21   // QOS_CLASS_USER_INTERACTIVE
        case .defaultQoS:      return 0x15   // QOS_CLASS_DEFAULT
        case .background:      return 0x09   // QOS_CLASS_BACKGROUND
        }
    }
}

final class CPULoad {
    private var queues: [DispatchQueue] = []
    private let stopFlag = ManagedAtomicFlag()

    /// Spawn `count` busy threads. `qos` steers the scheduler onto a cluster.
    func start(cores: [Int], count: Int? = nil, qos: LoadQoS = .defaultQoS) {
        let n = count ?? max(1, cores.count)
        let dq: DispatchQoS
        switch qos {
        case .userInteractive: dq = .userInteractive
        case .background:      dq = .background
        case .defaultQoS:      dq = .default
        }
        let queue = DispatchQueue(label: "smc.load", qos: dq, attributes: .concurrent)
        for _ in 0..<n {
            queue.async { [stopFlag] in
                var sink: UInt64 = 0
                while !stopFlag.isSet() {
                    // Pure arithmetic spin: keeps the core saturated without syscalls.
                    for i in 0..<1_000_000 { sink &+= UInt64(i &* 2654435761) }
                }
                if sink == UInt64.max { print("unreachable \(sink)") }
            }
        }
        queues.append(queue)
    }

    func stop() { stopFlag.set() }
}

final class ManagedAtomicFlag {
    private var value = false
    private let lock = NSLock()
    func isSet() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

// MARK: - GPU load generation (Metal Performance Shaders, no shader compiler needed)

final class GPULoad {
    private var running = true
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var texA: MTLTexture?
    private var texB: MTLTexture?
    private var blur: MPSImageGaussianBlur?
    /// Measured GPU-busy time of the last submitted batch (seconds).
    private(set) var lastGpuSeconds: Double = 0
    private let stopFlag = ManagedAtomicFlag()

    init?(size: Int = 4096, sigma: Float = 24) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: size, height: size, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        guard let a = device.makeTexture(descriptor: desc),
              let b = device.makeTexture(descriptor: desc) else { return nil }
        self.texA = a
        self.texB = b
        self.blur = MPSImageGaussianBlur(device: device, sigma: sigma)
    }

    /// One GPU-heavy batch: N gaussian blurs ping-ponged between two textures.
    func runBatches(iterations: Int) -> Bool {
        guard let queue = queue, let blur = blur, let a = texA, let b = texB else { return false }
        let t0 = Date()
        for _ in 0..<iterations {
            guard let cmd = queue.makeCommandBuffer() else { return false }
            var src = a
            var dst = b
            for _ in 0..<2 {
                blur.encode(commandBuffer: cmd, sourceTexture: src, destinationTexture: dst)
                swap(&src, &dst)
            }
            cmd.commit()
            // Sleep instead of spin-waiting: waitUntilCompleted() busy-waits on
            // some systems and would add CPU load, confounding the GPU test.
            Thread.sleep(forTimeInterval: 0.002)
            cmd.waitUntilCompleted()
        }
        lastGpuSeconds = Date().timeIntervalSince(t0)
        return true
    }

    func start() {
        let t = Thread { [weak self] in
            guard let self else { return }
            while !self.stopFlag.isSet() {
                if !self.runBatches(iterations: 4) { break }
            }
        }
        t.start()
    }

    func stop() { stopFlag.set() }
}

// MARK: - CPU utilisation (host_statistics)

/// Fraction of *all* CPU cores busy, 0...1.
/// HOST_CPU_LOAD_INFO returns *cumulative* tick counters, so we difference
/// consecutive samples to get a rate.
final class CPUUsage {
    private var last: (u: Int, s: Int, idle: Int, n: Int)? = nil
    func busyFraction() -> Double {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        let (u, s, idle, n) = info.cpu_ticks
        let cur = (Int(u), Int(s), Int(idle), Int(n))
        defer { last = cur }
        guard let prev = last else { return -1 }
        let dBusy = (cur.0 - prev.0) + (cur.1 - prev.1) + (cur.3 - prev.3)
        let dTotal = dBusy + (cur.2 - prev.2)
        guard dTotal > 0 else { return -1 }
        return Double(dBusy) / Double(dTotal)
    }
}

// MARK: - helpers

func fmt(_ d: Double?) -> String {
    guard let d else { return "n/a" }
    return String(format: "%.2f", d)
}

// MARK: - entry point

@main
struct Tool {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let mode = args.first ?? "enumerate"

        func opt(_ name: String) -> String? {
            if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
            return nil
        }
        func has(_ name: String) -> Bool { args.contains(name) }

        let smc: SMCClient
        do {
            smc = try SMCClient()
        } catch {
            FileHandle.standardError.write(("error: \(error)\n").data(using: .utf8)!)
            exit(1)
        }

        switch mode {
        case "enumerate":
            var max = 65536
            if let m = opt("--max").flatMap(Int.init) { max = m }
            let keys = smc.enumerateKeys(max: max)
            print("index\tkey\tdataType\ttypeName\tdataAttrs\tvers\tpLimit\tvalue")
            for (idx, k) in keys {
                let keyStr = SMCClient.string(k)
                guard let raw = smc.infoBytes(keyStr) else {
                    print("\(idx)\t\(keyStr)\tERR\t\t\t\t\t")
                    continue
                }
                let info = SMCKeyInfo(raw: raw)
                print("\(idx)\t\(keyStr)\t\(info.dataType)\t\(smcDataTypeNames[info.dataType] ?? "?")\t\(info.dataAttributes)\t\(info.version.0).\(info.version.1)\t\(info.pLimitSize)\t\(fmt(smc.read(keyStr)))")
            }

        case "info":
            for keyStr in args.dropFirst().filter({ !$0.hasPrefix("--") }) {
                guard let raw = smc.infoBytes(keyStr) else {
                    print("\(keyStr)\tERR (no key info)")
                    continue
                }
                let info = SMCKeyInfo(raw: raw)
                let hex = info.raw.prefix(30).map { String(format: "%02x", $0) }.joined()
                print("\(keyStr)\ttype=\(info.dataType) (\(smcDataTypeNames[info.dataType] ?? "?"))\tattrs=0x\(String(info.dataAttributes, radix: 16))\tvers=\(info.version.0).\(info.version.1)\tpLimit=\(info.pLimitSize)\tvalue=\(fmt(smc.read(keyStr)))\traw=\(hex)")
            }

        case "watch":
            // Key selection: explicit positional keys, or --temps (auto-discovered T* keys).
            var keys: [String] = args.dropFirst().filter { !$0.hasPrefix("--") && $0.count == 4 }
            if has("--temps") || keys.isEmpty {
                keys = smc.enumerateKeys().map { SMCClient.string($0.key) }
                    .filter { $0.hasPrefix("T") }
                    .filter { (smc.read($0) ?? -999) > 5 }   // plausible temperature range
                    .sorted()
            }
            let seconds = opt("--seconds").flatMap(Int.init) ?? 10
            let loadMode = opt("--load") ?? "none"
            let cores: [Int] = {
                guard let spec = opt("--cores") else { return Array(0..<ProcessInfo.processInfo.activeProcessorCount) }
                return spec.split(separator: ",").flatMap { rawPart -> [Int] in
                    let part = String(rawPart)
                    if let dash = part.firstIndex(of: "-"),
                       let a = Int(part[part.startIndex..<dash]),
                       let b = Int(part[part.index(after: dash)...]) {
                        return Array(a...b)
                    }
                    return Int(part).map { [$0] } ?? []
                }
            }()

            let preSeconds = opt("--pre").flatMap(Int.init) ?? 0
            let postSeconds = opt("--post").flatMap(Int.init) ?? 0
            var cpuLoad: CPULoad?
            var gpuLoad: GPULoad?

            var out = FileHandle.standardOutput
            if let path = opt("--out") {
                let url = URL(fileURLWithPath: path)
                if !FileManager.default.fileExists(atPath: path) {
                    FileManager.default.createFile(atPath: path, contents: nil)
                }
                if let h = FileHandle(forWritingAtPath: path) {
                    h.truncateFile(atOffset: 0)
                    out = h
                }
            }
            func emit(_ s: String) { out.write((s + "\n").data(using: .utf8)!) }

            emit((["t", "cpu%", "phase"] + keys).joined(separator: "\t"))
            let usage = CPUUsage()
            let t0 = Date()
            var phase = "idle"
            var elapsed = 0

            func sample(_ n: Int) {
                let busy = usage.busyFraction()
                let row = keys.map { fmt(smc.read($0)) }
                emit(String(format: "%.1f", Date().timeIntervalSince(t0)) + "\t"
                     + String(format: "%.1f", busy < 0 ? 0 : busy * 100) + "\t" + phase + "\t"
                     + row.joined(separator: "\t"))
                if n + 1 < total { Thread.sleep(forTimeInterval: 1.0) }
            }

            let total = preSeconds + seconds + postSeconds
            // phase 1: idle baseline
            for i in 0..<preSeconds { sample(i); elapsed += 1 }
            // phase 2: load
            phase = "load"
            if loadMode == "cpu" || loadMode == "both" {
                let l = CPULoad()
                let nthreads = opt("--threads").flatMap(Int.init)
                let qos = LoadQoS(rawValue: opt("--qos") ?? "default") ?? .defaultQoS
                l.start(cores: cores, count: nthreads, qos: qos)
                cpuLoad = l
                FileHandle.standardError.write("CPU load: \(nthreads ?? cores.count) threads, qos=0x\(String(qos.raw, radix: 16))\n".data(using: .utf8)!)
            }
            if loadMode == "gpu" || loadMode == "both" {
                if let g = GPULoad() {
                    gpuLoad = g
                    g.start()
                    FileHandle.standardError.write("GPU load (MPS gaussian blur)\n".data(using: .utf8)!)
                } else {
                    FileHandle.standardError.write("no Metal device\n".data(using: .utf8)!)
                }
            }
            for i in 0..<seconds { sample(i); elapsed += 1 }
            // phase 3: cooldown
            phase = "cooldown"
            cpuLoad?.stop()
            gpuLoad?.stop()
            for i in 0..<postSeconds { sample(i); elapsed += 1 }
            _ = elapsed

        default:
            print("usage: smc_keys [enumerate|watch|info] ...")
        }
    }
}
