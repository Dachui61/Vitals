import Darwin
import Foundation
import IOKit

/// 单调时钟（纳秒）。
///
/// **注意**：`mach_absolute_time` 在本机**不是纳秒**（24 MHz），换算速率时不能直接当纳秒用。
public func monotonicNanoseconds() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
}

// MARK: - GPU

/// GPU 占用与"占用系统内存"。
public struct GPUUsage: Equatable, Sendable {
    /// 设备占用百分比（与 Renderer % 恒等）。
    public let percent: Int
    /// GPU 正在占用的系统内存（统一内存机器上**没有显存**，所以这么叫）。
    public let memoryInUseBytes: UInt64
    /// macOS 划给 GPU 的系统内存总量。
    public let memoryAllocatedBytes: UInt64

    public init(percent: Int, memoryInUseBytes: UInt64, memoryAllocatedBytes: UInt64) {
        self.percent = percent
        self.memoryInUseBytes = memoryInUseBytes
        self.memoryAllocatedBytes = memoryAllocatedBytes
    }
}

/// GPU 采样：`AGXAccelerator` 的 `PerformanceStatistics`（**无特权可读**，18.95 µs）。
///
/// 坑：驱动每 ~250 ms 会把三个 Utilization **整组写成 0**，所以一次采样连读几次取最大值。
public final class GPUSampler {
    private var service: io_service_t = 0

    public init() {
        var iterator: io_iterator_t = 0
        if let matching = IOServiceMatching("IOAccelerator") {
            _ = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
            service = IOIteratorNext(iterator)
            IOObjectRelease(iterator)
        }
    }

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    /// 连读 `maxReads` 次取最大值（对抗周期性掉 0）。
    public func sample(maxReads: Int = 3) -> GPUUsage? {
        guard service != 0 else { return nil }
        var best: GPUUsage?
        for _ in 0..<maxReads {
            guard let properties = Self.properties(service, "PerformanceStatistics") else { continue }
            let device = (properties["Device Utilization %"] as? NSNumber)?.intValue ?? 0
            let memoryInUse = (properties["In use system memory"] as? NSNumber)?.uint64Value ?? 0
            let memoryAllocated = (properties["Alloc system memory"] as? NSNumber)?.uint64Value ?? 0
            if best == nil || device > best!.percent {
                best = GPUUsage(percent: device, memoryInUseBytes: memoryInUse, memoryAllocatedBytes: memoryAllocated)
            }
            usleep(5_000)
        }
        return best
    }

    static func properties(_ entry: io_service_t, _ key: String) -> [String: Any]? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return unmanaged.takeUnretainedValue() as? [String: Any]
    }
}

public struct GPUProviderImpl: MetricProvider {
    public typealias Output = GPUUsage

    private let sampler = GPUSampler()

    public init() {}

    public func sample() -> Metric<GPUUsage> {
        guard let usage = sampler.sample() else {
            return .unavailable(.backendUnavailable("未找到 AGXAccelerator 节点"))
        }
        return .value(usage, confidence: .approximate, source: "AGX PerformanceStatistics")
    }
}

// MARK: - 磁盘

/// 磁盘读写速率。
public struct DiskThroughput: Equatable, Sendable {
    public let bytesReadPerSecond: UInt64
    public let bytesWrittenPerSecond: UInt64

    public init(bytesReadPerSecond: UInt64, bytesWrittenPerSecond: UInt64) {
        self.bytesReadPerSecond = bytesReadPerSecond
        self.bytesWrittenPerSecond = bytesWrittenPerSecond
    }
}

/// 磁盘采样：IOKit `IOBlockStorageDriver` → `Statistics`（**无特权可读**，30.26 µs）。
///
/// 累计计数器做差分得速率。坑：节点里混着**磁盘映像**，直接求和会把映像的 IO 算进去。
public final class DiskSampler {
    private var drivers: [io_service_t] = []
    private var previous: [(read: UInt64, write: UInt64)] = []
    private var lastSampleNanoseconds: UInt64 = 0

    public init() {
        var iterator: io_iterator_t = 0
        if let matching = IOServiceMatching("IOBlockStorageDriver") {
            _ = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
            while true {
                let service = IOIteratorNext(iterator)
                if service == 0 { break }
                drivers.append(service)
            }
            IOObjectRelease(iterator)
        }
    }

    deinit {
        drivers.forEach { IOObjectRelease($0) }
    }

    public func sample() -> DiskThroughput? {
        var current: [(read: UInt64, write: UInt64)] = []
        for driver in drivers {
            guard let statistics = GPUSampler.properties(driver, "Statistics") else { continue }
            let read = (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            let write = (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            current.append((read, write))
        }
        defer { previous = current }
        guard !current.isEmpty, previous.count == current.count else { return nil }

        let now = monotonicNanoseconds()
        defer { lastSampleNanoseconds = now }
        guard lastSampleNanoseconds > 0, now > lastSampleNanoseconds else { return nil }
        let seconds = Double(now - lastSampleNanoseconds) / 1_000_000_000

        var readDelta: UInt64 = 0
        var writeDelta: UInt64 = 0
        for index in current.indices {
            readDelta += current[index].read &- previous[index].read
            writeDelta += current[index].write &- previous[index].write
        }
        return DiskThroughput(bytesReadPerSecond: UInt64(Double(readDelta) / seconds),
                              bytesWrittenPerSecond: UInt64(Double(writeDelta) / seconds))
    }
}

public struct DiskProviderImpl: MetricProvider {
    public typealias Output = DiskThroughput

    private let sampler = DiskSampler()

    public init() {}

    public func sample() -> Metric<DiskThroughput> {
        guard let throughput = sampler.sample() else {
            return .unavailable(.detecting)
        }
        return .value(throughput)
    }
}

// MARK: - 网络

/// 网络上下行速率。
public struct NetworkThroughput: Equatable, Sendable {
    public let bytesInPerSecond: UInt64
    public let bytesOutPerSecond: UInt64
    public let interfaceName: String

    public init(bytesInPerSecond: UInt64, bytesOutPerSecond: UInt64, interfaceName: String) {
        self.bytesInPerSecond = bytesInPerSecond
        self.bytesOutPerSecond = bytesOutPerSecond
        self.interfaceName = interfaceName
    }
}

/// 网络采样：`getifaddrs` + `if_data`（**无特权可读**，24.33 µs）。
///
/// 坑：`ifi_ibytes` / `ifi_obytes` 是 **32 位**计数器，4 GiB 回绕 —— 差分仍然正确。
/// 必须排除 loopback 与虚拟网卡（否则几十 GB 的背景流量淹没真实值）。
public final class NetworkSampler {
    private var previous: (rx: UInt64, tx: UInt64) = (0, 0)
    private var lastSampleNanoseconds: UInt64 = 0
    /// 虚拟网卡前缀：这些不计入。
    private static let virtualPrefixes = ["utun", "bridge", "vbox", "awdl", "llw", "gif", "stf", "anpi"]

    public init() {}

    public func sample() -> NetworkThroughput? {
        guard let interfaceName = Self.primaryInterface(),
              let counters = Self.bytes(for: interfaceName) else { return nil }

        let now = monotonicNanoseconds()
        defer { previous = counters; lastSampleNanoseconds = now }
        guard lastSampleNanoseconds > 0, now > lastSampleNanoseconds else { return nil }
        let seconds = Double(now - lastSampleNanoseconds) / 1_000_000_000

        return NetworkThroughput(
            bytesInPerSecond: UInt64(Double(counters.rx &- previous.rx) / seconds),
            bytesOutPerSecond: UInt64(Double(counters.tx &- previous.tx) / seconds),
            interfaceName: interfaceName
        )
    }

    /// 选一个"真实"网卡：非 loopback、非虚拟、在跑。
    static func primaryInterface() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let head = list else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        var fallback: String?
        while let entry = cursor {
            let name = String(cString: entry.pointee.ifa_name)
            let flags = entry.pointee.ifa_flags
            let isLoopback = flags & UInt32(IFF_LOOPBACK) != 0
            let isVirtual = virtualPrefixes.contains { name.hasPrefix($0) }
            let isUp = flags & UInt32(IFF_UP) != 0 && flags & UInt32(IFF_RUNNING) != 0
            if !isLoopback, !isVirtual {
                if isUp { return name }
                fallback = fallback ?? name
            }
            cursor = entry.pointee.ifa_next
        }
        return fallback
    }

    static func bytes(for name: String) -> (rx: UInt64, tx: UInt64)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let head = list else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let entry = cursor {
            if String(cString: entry.pointee.ifa_name) == name {
                let flags = entry.pointee.ifa_flags
                guard flags & UInt32(IFF_LOOPBACK) == 0,
                      let address = entry.pointee.ifa_addr,
                      address.pointee.sa_family == sa_family_t(AF_LINK),
                      let data = entry.pointee.ifa_data else { return nil }
                let counters = data.assumingMemoryBound(to: if_data.self)
                return (UInt64(counters.pointee.ifi_ibytes), UInt64(counters.pointee.ifi_obytes))
            }
            cursor = entry.pointee.ifa_next
        }
        return nil
    }
}

public struct NetworkProviderImpl: MetricProvider {
    public typealias Output = NetworkThroughput

    private let sampler = NetworkSampler()

    public init() {}

    public func sample() -> Metric<NetworkThroughput> {
        guard let throughput = sampler.sample() else {
            return .unavailable(.detecting)
        }
        return .value(throughput)
    }
}

// MARK: - 进程

/// 进程信息（只读）。
public struct ProcessRow: Equatable, Identifiable, Sendable {
    public let id: pid_t
    public let name: String
    public let residentBytes: UInt64
    /// 每进程 CPU 百分比——**实测不稳定**（见下），所以可能是 nil。
    public let cpuPercent: Double?

    public init(id: pid_t, name: String, residentBytes: UInt64, cpuPercent: Double?) {
        self.id = id
        self.name = name
        self.residentBytes = residentBytes
        self.cpuPercent = cpuPercent
    }
}

/// 进程采样：libproc（**天然只返回当前用户的进程** —— 别人的 pid 直接失败）。
///
/// 全量扫描 0.889 ms，所以刷新频率应低于指标采样（2–3 秒一次）。
///
/// **每进程 CPU% 不可靠**：`pti_total_user` 的纳秒值连续差分不自洽、`p_cpticks` 不动。
/// 因此这里只给 RSS 与名字，CPU% 暂不提供（宁可少一个数字，也不要给一个会骗人的数字）。
public enum ProcessSampler {

    public static func listCurrentUserProcesses(limit: Int = 5) -> [ProcessRow] {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count))
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(Int(count) * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }

        var rows: [ProcessRow] = []
        let infoSize = Int32(MemoryLayout<proc_taskallinfo>.size)
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var task = proc_taskallinfo()
            let written = withUnsafeMutablePointer(to: &task) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoSize)) { rebound in
                    proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, rebound, infoSize)
                }
            }
            guard written == infoSize else { continue }

            // 名字取 pbsd.pbi_comm（16 字节定长，proc_name 对部分进程会返回 0 长度）；
            // 常驻内存在 ptinfo.pti_resident_size；
            // CPU 时间在 ptinfo.pti_total_user（纳秒），但票 03 实测它的差分不自洽 → 不提供每进程 CPU%。
            let name = withUnsafeBytes(of: task.pbsd.pbi_comm) { raw -> String in
                let bytes = raw.prefix { $0 != 0 }
                let text = String(decoding: bytes, as: UTF8.self)
                return text.isEmpty ? "?" : text
            }

            rows.append(ProcessRow(id: pid,
                                   name: name,
                                   residentBytes: UInt64(task.ptinfo.pti_resident_size),
                                   cpuPercent: nil))
        }

        // 按常驻内存排序取前 N（CPU% 不可靠，不用它排序）
        rows.sort { $0.residentBytes > $1.residentBytes }
        return Array(rows.prefix(limit))
    }
}

/// 进程列表提供者。
public struct ProcessProviderImpl: MetricProvider {
    public typealias Output = [ProcessRow]

    private let limit: Int

    public init(limit: Int = 5) {
        self.limit = limit
    }

    public func sample() -> Metric<[ProcessRow]> {
        let processes = ProcessSampler.listCurrentUserProcesses(limit: limit)
        guard !processes.isEmpty else {
            return .unavailable(.backendUnavailable("libproc 没有返回任何进程"))
        }
        return .value(processes)
    }
}
