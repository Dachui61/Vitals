// VitalsMetrics.swift — 各指标后端的可复用实现（票 03 实测结论）
//
// 编译（本机只有 Command Line Tools）：
//   swiftc -swift-version 5 -O -parse-as-library \
//     -module-cache-path "$PWD/.modulecache" -Xcc -fmodules-cache-path="$PWD/.modulecache" \
//     -o /tmp/VitalsMetrics scratch/VitalsMetrics.swift \
//     -framework IOKit -framework Metal -framework Network
//
// 所有实测数字见 research/metric-backends.md。
import Foundation
import Darwin
import IOKit
import IOKit.ps
import Network

// MARK: - 计时

/// 本机 mach_absolute_time() 不是纳秒（24 MHz 时间基，10 s 墙钟只走 0.24 s）。
/// 测速统一用 CLOCK_MONOTONIC_RAW。
@inline(__always)
func vitalsMonotonicNS() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts)
    return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
}

func vitalsSysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
}

func vitalsSysctlInt(_ name: String) -> Int? {
    var v = 0
    var size = MemoryLayout<Int>.size
    guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
    return v
}

// MARK: - 1. 核型（超频核 / 性能核 / 能效核）

public enum CoreKind: String, CaseIterable {
    case superCore = "超频核"     // hw.perflevel0 "Super"
    case perfCore  = "性能核"     // hw.perflevel1 "Performance"
    case effCore   = "能效核"     // hw.perflevel2 "Efficiency"
}

public struct CoreTopology {
    /// 下标 = host_processor_info 数组下标 = 设备树 logical-cpu-id
    public let kindOfLogicalCPU: [CoreKind]
    public let namedLevelCounts: [(name: String, count: Int)]
}

public enum CoreTopologyReader {

    /// 读 IODeviceTree 的 cpus/cpuN@N 节点的 "cluster-type"。
    /// cluster-type 是 Apple 内部取值（E/P/M），靠「数量唯一匹配」映射到 sysctl 的命名 perflevel。
    /// 匹配不上就返回 nil —— 调用方必须降级为「不分组」，不能猜。
    public static func read() -> CoreTopology? {
        var namedLevels: [(name: String, count: Int)] = []
        let nLevels = vitalsSysctlInt("hw.nperflevels") ?? 0
        guard nLevels > 0 else { return nil }
        for l in 0..<nLevels {
            guard let c = vitalsSysctlInt("hw.perflevel\(l).logicalcpu"),
                  let n = vitalsSysctlString("hw.perflevel\(l).name") else { return nil }
            namedLevels.append((n, c))
        }

        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return nil }

        // 设备树节点不在 kIOServicePlane 里，必须用 IORegistryEntryCreateIterator + 显式指定 plane。
        var byType: [String: [Int]] = [:]
        var iter: io_iterator_t = 0
        let kr = "IODeviceTree".withCString { plane in
            IORegistryEntryCreateIterator(cpus, plane, UInt32(kIORegistryIterateRecursively), &iter)
        }
        guard kr == KERN_SUCCESS else { return nil }
        while true {
            let e = IOIteratorNext(iter)
            if e == 0 { break }
            defer { IOObjectRelease(e) }
            guard let type = CoreTopologyReader.ioregString(e, "cluster-type"),
                  let id = CoreTopologyReader.ioregInt(e, "logical-cpu-id") else { continue }
            byType[type, default: []].append(Int(id))
        }
        guard !byType.isEmpty else { return nil }

        // 数量匹配：cluster-type "E" 的个数必须等于某个命名 level 的数量；
        // 剩下的类型与剩下的 level 按数量一一配对（唯一解时才成立）。
        var typeCounts = byType.mapValues { $0.count }
        var levelCounts = namedLevels.map { $0.count }
        guard typeCounts.count == levelCounts.count else { return nil }

        var typeToLevel: [String: String] = [:]
        // 先匹配唯一的同数量对
        var usedLevels = Set<Int>()
        for (type, cnt) in typeCounts {
            let candidates = namedLevels.indices.filter { levelCounts[$0] == cnt && !usedLevels.contains($0) }
            guard candidates.count == 1 else { continue }
            typeToLevel[type] = namedLevels[candidates[0]].name
            usedLevels.insert(candidates[0])
        }
        // 剩下的再按剩余数量配对
        var remainingTypes = typeCounts.filter { typeToLevel[$0.key] == nil }
        var remainingLevels = namedLevels.indices.filter { !usedLevels.contains($0) }
        if remainingTypes.count == remainingLevels.count, remainingTypes.count <= 1 {
            if let t = remainingTypes.first, let l = remainingLevels.first {
                typeToLevel[t.key] = namedLevels[l].name
                usedLevels.insert(l)
            }
        }
        guard typeToLevel.count == typeCounts.count else { return nil }

        var kindByName: [String: CoreKind] = [:]
        kindByName["Super"] = .superCore
        kindByName["Performance"] = .perfCore
        kindByName["Efficiency"] = .effCore

        let total = namedLevels.reduce(0) { $0 + $1.count }
        var kinds = [CoreKind?](repeating: nil, count: total)
        for (type, indices) in byType {
            guard let levelName = typeToLevel[type], let kind = kindByName[levelName] else { return nil }
            for idx in indices where idx < total { kinds[idx] = kind }
        }
        guard kinds.allSatisfy({ $0 != nil }) else { return nil }
        return CoreTopology(kindOfLogicalCPU: kinds.map { $0! }, namedLevelCounts: namedLevels)
    }

    // MARK: IOKit 小工具
    static func ioregString(_ e: io_service_t, _ key: String) -> String? {
        guard let u = IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0) else { return nil }
        let v = u.takeUnretainedValue()
        if let s = v as? String { return s }
        // 设备树的 cluster-type 是 CFData（2 字节 "E\0"）
        if let d = v as? Data, let first = d.first, first != 0 {
            return String(UnicodeScalar(first))
        }
        return nil
    }
    static func ioregInt(_ e: io_service_t, _ key: String) -> Int? {
        guard let u = IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0) else { return nil }
        if let n = u.takeUnretainedValue() as? NSNumber { return n.intValue }
        return nil
    }
}

// MARK: - 2. CPU（总量 + 每核）

public struct CPUTicks {
    public var perCore: [[natural_t]] = []   // 每核 [user, system, idle, nice]
    public var count: Int { perCore.count }
}

public enum CPUSampler {

    /// host_processor_info 返回的数组由内核分配，调用方必须 vm_deallocate。
    /// 实测 8.23 µs/次（12 核，1000 次迭代）。
    public static func readTicks() -> CPUTicks {
        var out = CPUTicks()
        var cnt = mach_msg_type_number_t(0)
        var arr: processor_info_array_t? = nil
        var acnt = mach_msg_type_number_t(0)
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cnt, &arr, &acnt) == KERN_SUCCESS,
              let arr = arr else { return out }
        for i in 0..<Int(cnt) {
            // processor_info_array_t 实际是 integer_t*，必须重解释
            let p = UnsafeMutableRawPointer(arr)
                .advanced(by: i * MemoryLayout<processor_cpu_load_info>.size)
                .assumingMemoryBound(to: processor_cpu_load_info.self)
            out.perCore.append([p.pointee.cpu_ticks.0, p.pointee.cpu_ticks.1,
                                p.pointee.cpu_ticks.2, p.pointee.cpu_ticks.3])
        }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: arr),
                      vm_size_t(acnt) * vm_size_t(MemoryLayout<natural_t>.size))
        return out
    }

    /// 本机实测 TH_CPU_SCALE == 100（1 tick = 10 ms），不是 1000。
    /// 百分比与比例无关，但把 tick 换算成 CPU 秒时必须用这个值。
    public static let tickScalePerSecond: Double = 100.0

    /// busy% = (user + sys + nice) / (user + sys + idle + nice)，idle 之外都算忙。
    public static func busyPercent(current: CPUTicks, previous: CPUTicks) -> (total: Double, perCore: [Double]) {
        var perCore: [Double] = []
        var u = 0, s = 0, id = 0, n = 0
        for i in 0..<min(current.count, previous.count) {
            let du = Int(current.perCore[i][0] &- previous.perCore[i][0])
            let ds = Int(current.perCore[i][1] &- previous.perCore[i][1])
            let di = Int(current.perCore[i][2] &- previous.perCore[i][2])
            let dn = Int(current.perCore[i][3] &- previous.perCore[i][3])
            u += du; s += ds; id += di; n += dn
            let tot = du + ds + di + dn
            perCore.append(tot > 0 ? Double(tot - di) * 100.0 / Double(tot) : 0)
        }
        let tot = u + s + id + n
        return (tot > 0 ? Double(tot - id) * 100.0 / Double(tot) : 0, perCore)
    }
}

/// 平滑：菜单栏用 3 点滑动平均（实测立刻贴住真值），告警判定用原始值。
public struct MovingAverage3 {
    private var buf: [Double] = []
    public mutating func push(_ v: Double) -> Double {
        buf.append(v)
        if buf.count > 3 { buf.removeFirst() }
        return buf.reduce(0, +) / Double(buf.count)
    }
    public var value: Double { buf.isEmpty ? 0 : buf.reduce(0, +) / Double(buf.count) }
}

// MARK: - 3. 内存

public struct MemorySample {
    public var totalBytes: UInt64 = 0
    public var usedBytes: UInt64 = 0            // App + Wired + Compressed（活动监视器口径）
    public var appBytes: UInt64 = 0
    public var wiredBytes: UInt64 = 0
    public var compressedBytes: UInt64 = 0
    public var freeBytes: UInt64 = 0
    public var swapUsedBytes: UInt64 = 0
    public var swapTotalBytes: UInt64 = 0
    public var pressureLevel: Int = 0           // 1=normal 2=warn 4=critical
}

public enum MemorySampler {

    /// host_statistics64(HOST_VM_INFO64)，实测 0.58 µs。
    /// 用 4 KiB 对齐的大缓冲读，再解释前 N 个字段 —— 避免 SDK 与内核结构体大小不一致时内核写超界。
    public static func sample() -> MemorySample {
        var s = MemorySample()
        let pageSize = UInt64(vitalsSysctlInt("hw.pagesize") ?? 16 * 1024)
        s.totalBytes = ProcessInfo.processInfo.physicalMemory

        let scratchWords = 1024
        var scratch = [UInt64](repeating: 0, count: scratchWords)
        var count = mach_msg_type_number_t(scratchWords)
        scratch.withUnsafeMutableBytes { raw in
            let p = raw.baseAddress!.assumingMemoryBound(to: integer_t.self)
            _ = host_statistics64(mach_host_self(), HOST_VM_INFO64, p, &count)
        }
        var vm = vm_statistics64()
        withUnsafeMutableBytes(of: &vm) { dst in
            let bytes = min(Int(count) * MemoryLayout<integer_t>.size, MemoryLayout<vm_statistics64>.size)
            dst.copyBytes(from: UnsafeRawBufferPointer(start: scratch, count: bytes))
        }

        let activeInternal = UInt64(vm.active_internal_count) * pageSize
        let inactiveInternal = UInt64(vm.inactive_internal_count) * pageSize
        let purgeable = UInt64(vm.purgeable_count) * pageSize
        s.appBytes = activeInternal + inactiveInternal - purgeable
        s.wiredBytes = UInt64(vm.wire_count) * pageSize
        s.compressedBytes = UInt64(vm.compressor_page_count) * pageSize
        s.freeBytes = UInt64(vm.free_count) * pageSize
        s.usedBytes = s.appBytes + s.wiredBytes + s.compressedBytes

        // swap：xsu_total/xsu_avail/xsu_used 的单位是【字节】，不是页
        var xsu = xsw_usage()
        var xsz = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &xsu, &xsz, nil, 0) == 0 {
            s.swapUsedBytes = xsu.xsu_used
            s.swapTotalBytes = xsu.xsu_total
        }
        s.pressureLevel = vitalsSysctlInt("kern.memorystatus_vm_pressure_level") ?? 0
        return s
    }

    private struct xsw_usage {
        var xsu_total: UInt64 = 0
        var xsu_avail: UInt64 = 0
        var xsu_used: UInt64 = 0
        var xsu_pagesize: Int32 = 0
        var xsu_encrypted: Int32 = 0
    }
}

// MARK: - 4. GPU

public struct GPUSample {
    public var deviceUtilization: Int = 0        // Device %（与 Renderer % 恒等）
    public var rendererUtilization: Int = 0
    public var tilerUtilization: Int = 0
    public var memoryInUseBytes: UInt64 = 0       // 「GPU 占用系统内存」，不是显存
    public var memoryAllocatedBytes: UInt64 = 0    // macOS 划给 GPU 的系统内存（静态）
    public var available = false
}

public final class GPUSampler {
    private var service: io_service_t = 0
    public init() {
        var it: io_iterator_t = 0
        if let m = IOServiceMatching("IOAccelerator") {
            _ = IOServiceGetMatchingServices(kIOMainPortDefault, m, &it)
            service = IOIteratorNext(it)
            IOObjectRelease(it)
        }
    }
    deinit { if service != 0 { IOObjectRelease(service) } }

    /// 驱动每 ~250 ms 会把三个 Utilization 整组写成 0，
    /// 所以一次采样连读几次取【最大值】。实测单次读 18.95 µs。
    public func sample(maxReads: Int = 3) -> GPUSample {
        guard service != 0 else { return GPUSample() }
        var best = GPUSample()
        for _ in 0..<maxReads {
            guard let props = GPUSampler.properties(service, "PerformanceStatistics") else { continue }
            let dev = (props["Device Utilization %"] as? NSNumber)?.intValue ?? 0
            let ren = (props["Renderer Utilization %"] as? NSNumber)?.intValue ?? 0
            let til = (props["Tiler Utilization %"] as? NSNumber)?.intValue ?? 0
            if dev > best.deviceUtilization {
                best.deviceUtilization = dev
                best.rendererUtilization = ren
                best.tilerUtilization = til
                best.memoryInUseBytes = (props["In use system memory"] as? NSNumber)?.uint64Value ?? 0
                best.memoryAllocatedBytes = (props["Alloc system memory"] as? NSNumber)?.uint64Value ?? 0
                best.available = true
            }
            usleep(5_000)
        }
        return best
    }

    static func properties(_ e: io_service_t, _ key: String) -> [String: Any]? {
        guard let u = IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0) else { return nil }
        return u.takeUnretainedValue() as? [String: Any]
    }
}

// MARK: - 5. 磁盘

public struct DiskSample {
    public var bytesReadPerSecond: UInt64 = 0
    public var bytesWrittenPerSecond: UInt64 = 0
    public var available = false
}

/// IOKit IOBlockStorageDriver → "Statistics"，【无特权可读】，实测 30.26 µs（4 个节点）。
/// 是累计计数器，做差分得速率。必须排除磁盘映像节点。
public final class DiskSampler {
    private var drivers: [io_service_t] = []
    private var previous: [(read: UInt64, write: UInt64)] = []
    private var lastSampleNS: UInt64 = 0

    public init() {
        var it: io_iterator_t = 0
        if let m = IOServiceMatching("IOBlockStorageDriver") {
            _ = IOServiceGetMatchingServices(kIOMainPortDefault, m, &it)
            while true {
                let s = IOIteratorNext(it)
                if s == 0 { break }
                drivers.append(s)
            }
            IOObjectRelease(it)
        }
    }
    deinit { drivers.forEach { IOObjectRelease($0) } }

    public func sample() -> DiskSample {
        var now: [(read: UInt64, write: UInt64)] = []
        for d in drivers {
            guard let stats = GPUSampler.properties(d, "Statistics") else { continue }
            let r = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            let w = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            now.append((r, w))
        }
        defer { previous = now }
        guard previous.count == now.count, !now.isEmpty else { return DiskSample() }
        let t = vitalsMonotonicNS()
        defer { lastSampleNS = t }
        guard lastSampleNS > 0, t > lastSampleNS else { return DiskSample() }
        let dt = Double(t - lastSampleNS) / 1e9
        var dr: UInt64 = 0, dw: UInt64 = 0
        for i in now.indices {
            dr += now[i].read &- previous[i].read
            dw += now[i].write &- previous[i].write
        }
        return DiskSample(bytesReadPerSecond: UInt64(Double(dr) / dt),
                          bytesWrittenPerSecond: UInt64(Double(dw) / dt),
                          available: true)
    }
}

// MARK: - 6. 网络

public struct NetSample {
    public var rxPerSecond: UInt64 = 0
    public var txPerSecond: UInt64 = 0
    public var interfaceName: String = ""
    public var available = false
}

/// getifaddrs + if_data，【无特权可读】，实测 24.33 µs。
/// 坑：ifi_ibytes/ifi_obytes 是 32 位计数器，4 GiB 回绕 —— 差分仍正确。
public final class NetSampler {
    private var previous: (rx: UInt64, tx: UInt64) = (0, 0)
    private var lastSampleNS: UInt64 = 0

    public init() {}

    /// 只统计指定接口（用 NWPathMonitor 拿当前在用的那个），排除 loopback 与虚拟网卡。
    public func sample(interfaceName: String) -> NetSample {
        guard let cur = NetSampler.bytes(for: interfaceName) else { return NetSample() }
        let t = vitalsMonotonicNS()
        defer { previous = cur; lastSampleNS = t }
        guard lastSampleNS > 0, t > lastSampleNS else { return NetSample() }
        let dt = Double(t - lastSampleNS) / 1e9
        return NetSample(rxPerSecond: UInt64(Double(cur.rx &- previous.rx) / dt),
                         txPerSecond: UInt64(Double(cur.tx &- previous.tx) / dt),
                         interfaceName: interfaceName,
                         available: true)
    }

    static func bytes(for name: String) -> (rx: UInt64, tx: UInt64)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let head = list else { return nil }
        defer { freeifaddrs(head) }
        var cur: UnsafeMutablePointer<ifaddrs>? = head
        while let p = cur {
            let ifName = String(cString: p.pointee.ifa_name)
            if ifName == name {
                let flags = p.pointee.ifa_flags
                if flags & UInt32(IFF_LOOPBACK) == 0,
                   let sa = p.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_LINK),
                   let data = p.pointee.ifa_data {
                    let d = data.assumingMemoryBound(to: if_data.self)
                    return (UInt64(d.pointee.ifi_ibytes), UInt64(d.pointee.ifi_obytes))
                }
                return nil
            }
            cur = p.pointee.ifa_next
        }
        return nil
    }
}

// MARK: - 7. 进程 Top

public struct ProcInfoRow {
    public var pid: pid_t = 0
    public var name: String = ""
    public var uid: uid_t = 0
    public var residentBytes: UInt64 = 0
    public var cpuPercent: Double = 0     // 需要自行验证差分稳定性，见报告 §6.3
}

public enum ProcSampler {
    /// libproc：只返回当前用户的进程（别人的 pid 进程 proc_pidinfo 直接失败），
    /// 所以「只看自己的进程」是白送的。全量 662 个进程扫一遍 0.889 ms。
    public static func listCurrentUserProcesses() -> [ProcInfoRow] {
        let cap = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard cap > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(cap) / MemoryLayout<pid_t>.stride + 16)
        let n = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &buf,
                              Int32(buf.count * MemoryLayout<pid_t>.stride))
        guard n > 0 else { return [] }
        let pids = Array(buf[0..<(Int(n) / MemoryLayout<pid_t>.stride)])

        var rows: [ProcInfoRow] = []
        for pid in pids {
            guard let bsd = ProcSampler.bsdInfo(pid), let task = ProcSampler.taskInfo(pid) else { continue }
            var row = ProcInfoRow()
            row.pid = pid
            row.uid = bsd.pbi_uid
            row.residentBytes = task.ptinfo.pti_resident_size
            var comm = [UInt8](repeating: 0, count: 17)
            let off = MemoryLayout<proc_bsdinfo>.offset(of: \.pbi_comm) ?? 0
            let size = MemoryLayout<proc_bsdinfo>.size
            let tmp = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<proc_bsdinfo>.alignment)
            defer { tmp.deallocate() }
            tmp.storeBytes(of: bsd, as: proc_bsdinfo.self)
            let bytes = UnsafeRawBufferPointer(start: tmp.advanced(by: off), count: 17)
            row.name = String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            rows.append(row)
        }
        return rows
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        let size = MemoryLayout<proc_bsdinfo>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<proc_bsdinfo>.alignment)
        defer { raw.deallocate() }
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, raw, Int32(size))
        guard n == Int32(size) else { return nil }
        return raw.load(as: proc_bsdinfo.self)
    }
    static func taskInfo(_ pid: pid_t) -> proc_taskallinfo? {
        let size = MemoryLayout<proc_taskallinfo>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<proc_taskallinfo>.alignment)
        defer { raw.deallocate() }
        let n = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, raw, Int32(size))
        guard n == Int32(size) else { return nil }
        return raw.load(as: proc_taskallinfo.self)
    }
}

// MARK: - 8. 电源状态

public enum PowerSourceState: String {
    case acPower = "交流电"
    case noBattery = "无电池"
    case unknown = "不可用"
}

public enum PowerSampler {
    /// AppleSmartBattery 的 BatteryInstalled / ExternalConnected，
    /// 【无特权可读】，单属性 2.42 µs。
    public static func state() -> (state: PowerSourceState, isCharging: Bool) {
        var it: io_iterator_t = 0
        guard let m = IOServiceMatching("AppleSmartBattery") else { return (.unknown, false) }
        _ = IOServiceGetMatchingServices(kIOMainPortDefault, m, &it)
        let svc = IOIteratorNext(it)
        IOObjectRelease(it)
        guard svc != 0 else { return (.unknown, false) }
        defer { IOObjectRelease(svc) }
        guard let installed = CoreTopologyReader.ioregInt(svc, "BatteryInstalled"),
              let external = CoreTopologyReader.ioregInt(svc, "ExternalConnected") else {
            return (.unknown, false)
        }
        let charging = (CoreTopologyReader.ioregInt(svc, "IsCharging") ?? 0) != 0
        if installed == 0 && external == 1 { return (.acPower, charging) }
        if installed == 0 { return (.noBattery, charging) }
        return (.unknown, charging)
    }

    /// IOPSCopyPowerSourcesInfo() 在本机返回【非 nil 但 source 列表为空】。
    public static func hasAnyPowerSource() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let arr = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        return !arr.isEmpty
    }
}

// MARK: - 自测入口
// swiftc -swift-version 5 -O -parse-as-library ... -o scratch/bin/VitalsMetrics scratch/VitalsMetrics.swift -framework IOKit -framework Metal -framework Network
// ./scratch/bin/VitalsMetrics
@main
struct VitalsMetricsDemo {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        print("=== 核型 ===")
        if let topo = CoreTopologyReader.read() {
            for (i, k) in topo.kindOfLogicalCPU.enumerated() {
                print("  逻辑核 \(i) -> \(k.rawValue)")
            }
            print("  perflevel 计数: \(topo.namedLevelCounts)")
        } else {
            print("  不可用（降级为不分组）")
        }

        print("\n=== CPU ===")
        var cpuPrev = CPUSampler.readTicks()
        Thread.sleep(forTimeInterval: 1.0)
        let cpuNow = CPUSampler.readTicks()
        let (total, perCore) = CPUSampler.busyPercent(current: cpuNow, previous: cpuPrev)
        print("  总量 busy=\(String(format: "%.2f", total))%  每核=\(perCore.map { String(format: "%.0f", $0) }.joined(separator: " "))")
        cpuPrev = cpuNow

        print("\n=== 内存 ===")
        let mem = MemorySampler.sample()
        print(String(format: "  已用 %.2f GiB / %.2f GiB (%.1f%%)  app=%.2f wired=%.2f compressed=%.2f",
                     Double(mem.usedBytes)/1073741824, Double(mem.totalBytes)/1073741824,
                     Double(mem.usedBytes)*100/Double(mem.totalBytes),
                     Double(mem.appBytes)/1073741824, Double(mem.wiredBytes)/1073741824,
                     Double(mem.compressedBytes)/1073741824))
        print(String(format: "  swap %.0f MiB / %.0f MiB  压力等级=%d",
                     Double(mem.swapUsedBytes)/1048576, Double(mem.swapTotalBytes)/1048576, mem.pressureLevel))

        print("\n=== GPU ===")
        let gpu = GPUSampler()
        let g = gpu.sample()
        print(String(format: "  device=%d%% renderer=%d%% tiler=%d%%  GPU 占用系统内存=%.2f GiB（划给 GPU=%.2f GiB）",
                     g.deviceUtilization, g.rendererUtilization, g.tilerUtilization,
                     Double(g.memoryInUseBytes)/1073741824, Double(g.memoryAllocatedBytes)/1073741824))

        print("\n=== 磁盘 ===")
        let disk = DiskSampler()
        _ = disk.sample()                 // 第一次只建基线
        Thread.sleep(forTimeInterval: 1.0)
        let d = disk.sample()
        print(String(format: "  读 %.1f KB/s  写 %.1f KB/s", Double(d.bytesReadPerSecond)/1024, Double(d.bytesWrittenPerSecond)/1024))

        print("\n=== 网络 ===")
        let net = NetSampler()
        let path = NWPathMonitor()
        let sem = DispatchSemaphore(value: 0)
        var activeIface: String? = nil
        path.pathUpdateHandler = { p in
            activeIface = p.availableInterfaces.first { $0.type == .wifi || $0.type == .wiredEthernet }?.name
            sem.signal()
        }
        path.start(queue: DispatchQueue.global())
        _ = sem.wait(timeout: .now() + 3)
        path.cancel()
        if let iface = activeIface {
            _ = net.sample(interfaceName: iface)
            Thread.sleep(forTimeInterval: 1.0)
            let n = net.sample(interfaceName: iface)
            print(String(format: "  %@  收 %.1f KB/s  发 %.1f KB/s", iface,
                         Double(n.rxPerSecond)/1024, Double(n.txPerSecond)/1024))
        } else {
            print("  不可用")
        }

        print("\n=== 进程（当前用户） ===")
        let rows = ProcSampler.listCurrentUserProcesses()
        print("  \(rows.count) 个进程；前 5 个按 RSS：")
        for r in rows.sorted(by: { $0.residentBytes > $1.residentBytes }).prefix(5) {
            print(String(format: "    pid=%d %@ rss=%.1f MiB uid=%d", r.pid, r.name, Double(r.residentBytes)/1048576, r.uid))
        }

        print("\n=== 电源 ===")
        let pwr = PowerSampler.state()
        print("  状态=\(pwr.state.rawValue)  充电中=\(pwr.isCharging)  有电源源列表=\(PowerSampler.hasAnyPowerSource())")
    }
}
