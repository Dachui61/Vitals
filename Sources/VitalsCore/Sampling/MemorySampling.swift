import Darwin
import Foundation

/// 内存采样。
///
/// ## 口径
///
/// **已用 = (active + inactive − purgeable) + wired + compressed**，
/// 也就是"系统里正在被用掉的物理内存"，与 `top -l 1` 的 `PhysMem: used` 同一口径。
/// （活动监视器的「Memory Used」= App + Wired + Compressed，**不含 file-backed**，所以两个数字天然不同：
/// 本机活动监视器约 10 GB，而 `top` 的 used 约 15 GB。）
///
/// ## 为什么不用 SDK 的 `vm_statistics64` 结构体
///
/// `host_statistics64` 返回的**长度是不可靠的**：同一个二进制里，
/// 独立编译的进程会拿到 104 个 4 字节整数（= 416 字节，恰好填满 `vm_statistics64`），
/// 而 SwiftPM 构建出来的进程只拿到 40 个（= 160 字节）——结构体后半段的
/// `external_page_count` / `internal_page_count` / `active_internal_count` 全是 0。
/// 照着返回长度拷贝会静默少读一大半字段（曾经因此把内存显示成 4.9 GB，真值是 14.7 GB）。
///
/// 所以这里**只用经验验证过的原始整数下标**，并对每个值做合理性校验。
/// 下标由本机 `vm_stat` 逐项对照确认（2026-11-15）：
///
/// | 下标 | 含义 | vm_stat 对照 |
/// |---|---|---|
/// | 1 | active | Pages active |
/// | 2 | inactive | Pages inactive |
/// | 3 | wired down | Pages wired down |
/// | 22 | purgeable | Pages purgeable |
/// | 23 | speculative | Pages speculative |
/// | 32 | compressor 占用 | Pages occupied by compressor |
public enum MemorySampler {

    /// 采样结果。
    public struct Sample: Equatable, Sendable {
        /// 已用字节 = (active + inactive − purgeable + wired + compressed) × pageSize。
        public var usedBytes: UInt64 = 0
        /// App 类内存 = (active + inactive − purgeable) × pageSize。
        public var appBytes: UInt64 = 0
        public var wiredBytes: UInt64 = 0
        public var compressedBytes: UInt64 = 0
        public var freeBytes: UInt64 = 0
        public var totalBytes: UInt64 = 0
        public var swapUsedBytes: UInt64 = 0
        public var swapTotalBytes: UInt64 = 0
        /// 1 = normal，2 = warn，4 = critical。
        public var pressureLevel: Int = 0
    }

    /// 原始整数下标（经验验证）。
    private enum Index {
        static let active = 1
        static let inactive = 2
        static let wired = 3
        static let purgeable = 22
        static let speculative = 23
        static let compressor = 32
        /// 需要的最小长度：至少要覆盖 compressor。
        static let minimumCount = 33
    }

    public static func sample() -> Sample {
        var sample = Sample()
        let pageSize = UInt64(sysctlValue.int("hw.pagesize") ?? 16 * 1024)
        sample.totalBytes = ProcessInfo.processInfo.physicalMemory
        let totalPages = sample.totalBytes / max(pageSize, 1)

        // 用大缓冲读，解释前 N 个 4 字节整数。
        let wordCount = 1024
        var scratch = [UInt64](repeating: 0, count: wordCount)
        var count = mach_msg_type_number_t(wordCount)
        scratch.withUnsafeMutableBytes { raw in
            let pointer = raw.baseAddress!.assumingMemoryBound(to: integer_t.self)
            _ = host_statistics64(mach_host_self(), HOST_VM_INFO64, pointer, &count)
        }
        guard count >= Index.minimumCount else { return sample }

        let integers = scratch.withUnsafeBytes { raw -> [Int64] in
            let pointer = raw.baseAddress!.assumingMemoryBound(to: Int32.self)
            return (0..<Int(count)).map { Int64(pointer[$0]) }
        }

        func pages(_ index: Int) -> Int64 {
            guard index < integers.count else { return 0 }
            return integers[index]
        }

        let active = pages(Index.active)
        let inactive = pages(Index.inactive)
        let wired = pages(Index.wired)
        let purgeable = pages(Index.purgeable)
        let compressor = pages(Index.compressor)

        // 合理性校验：任何一个超出总页数就说明这次读不可信 → 整份作废（显示不可用，不显示 0）。
        let ceiling = Int64(totalPages)
        let values = [active, inactive, wired, purgeable, compressor]
        guard values.allSatisfy({ $0 >= 0 && $0 <= ceiling }) else { return sample }

        let appPages = max(0, active + inactive - purgeable)
        sample.appBytes = UInt64(appPages) * pageSize
        sample.wiredBytes = UInt64(wired) * pageSize
        sample.compressedBytes = UInt64(compressor) * pageSize
        sample.usedBytes = sample.appBytes + sample.wiredBytes + sample.compressedBytes

        // swap：xsu_total / xsu_avail / xsu_used 的单位是【字节】，不是页。
        var usage = XSWUsage()
        var size = MemoryLayout<XSWUsage>.size
        if sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 {
            sample.swapUsedBytes = usage.xsu_used
            sample.swapTotalBytes = usage.xsu_total
        }

        sample.pressureLevel = sysctlValue.int("kern.memorystatus_vm_pressure_level") ?? 0
        return sample
    }

    /// `vm.swapusage` 的结构（sysctl 私有，但布局稳定）。
    struct XSWUsage {
        var xsu_total: UInt64 = 0
        var xsu_avail: UInt64 = 0
        var xsu_used: UInt64 = 0
        var xsu_pagesize: Int32 = 0
        var xsu_encrypted: Int32 = 0
    }
}

/// 内存指标提供者。
public struct MemoryProviderImpl: MetricProvider {
    public typealias Output = MemoryUsage

    public init() {}

    public func sample() -> Metric<MemoryUsage> {
        let sample = MemorySampler.sample()
        guard sample.totalBytes > 0, sample.usedBytes > 0 else {
            return .unavailable(.backendUnavailable("host_statistics64 未返回可用的内存信息"))
        }
        let pressure: MemoryPressure
        switch sample.pressureLevel {
        case 2: pressure = .warn
        case 4: pressure = .critical
        default: pressure = .normal
        }
        return .value(MemoryUsage(
            usedBytes: sample.usedBytes,
            totalBytes: sample.totalBytes,
            pressure: pressure,
            swapUsedBytes: sample.swapUsedBytes
        ))
    }
}
