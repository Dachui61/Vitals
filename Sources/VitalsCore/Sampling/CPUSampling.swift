import Darwin
import Foundation

/// 一次 CPU tick 采样：每核 4 个计数（user / sys / idle / nice）。
public struct CPUTicks: Equatable, Sendable {
    public var perCore: [[Int]]

    public init(perCore: [[Int]] = []) {
        self.perCore = perCore
    }
}

/// CPU 占用计算。**纯逻辑**（不碰 Mach），可单测。
///
/// 口径（票 03 实测）：busy% = (user + sys + nice) / (user + sys + idle + nice)，
/// idle 之外都算忙。本机 tick 比例是 **100/s**（不是 1000/s），换算 CPU 秒时必须用 100。
public struct CPUBusyCalculator {
    public static let tickScalePerSecond: Double = 100

    public init() {}

    /// 由两次 tick 算占用。首次没有基准、或基准不可比时返回 nil。
    public static func busyPercent(current: CPUTicks, previous: CPUTicks) -> (total: Double, perCore: [Double])? {
        guard !current.perCore.isEmpty, current.perCore.count == previous.perCore.count else { return nil }

        var perCore: [Double] = []
        perCore.reserveCapacity(current.perCore.count)

        var sumUser = 0, sumSys = 0, sumIdle = 0, sumNice = 0

        for index in current.perCore.indices {
            let now = current.perCore[index]
            let before = previous.perCore[index]
            guard now.count >= 4, before.count >= 4 else { return nil }

            // 无符号回绕：计数可能因回绕变小，用 &- 处理。
            let dUser = Int(now[0] &- before[0])
            let dSys = Int(now[1] &- before[1])
            let dIdle = Int(now[2] &- before[2])
            let dNice = Int(now[3] &- before[3])

            // 计数器回绕/重置会让差值变成巨大的正数 → 判为不可比。
            let total = dUser + dSys + dIdle + dNice
            guard total >= 0 else { return nil }

            sumUser += dUser
            sumSys += dSys
            sumIdle += dIdle
            sumNice += dNice

            perCore.append(total > 0 ? Double(total - dIdle) * 100.0 / Double(total) : 0)
        }

        let totalTicks = sumUser + sumSys + sumIdle + sumNice
        guard totalTicks > 0 else { return nil }
        let totalPercent = Double(totalTicks - sumIdle) * 100.0 / Double(totalTicks)
        return (totalPercent, perCore)
    }
}

/// 持有一帧基准，逐次喂入 tick 就算出占用。
public struct CPUBusyTracker {
    private var previous: CPUTicks?

    public init() {}


    /// 第一次调用返回 nil（还没有差分基准），之后每次都给出新值。
    public mutating func update(with ticks: CPUTicks) -> (total: Double, perCore: [Double])? {
        defer { previous = ticks }
        guard let previous else { return nil }
        return CPUBusyCalculator.busyPercent(current: ticks, previous: previous)
    }
}

/// 真实 CPU 采集：Mach API。
public enum MachCPUSampler {
    /// `host_processor_info` 返回的数组由内核分配，**调用方必须 vm_deallocate**，
    /// 否则每秒泄漏几百字节。
    public static func readTicks() -> CPUTicks {
        var ticks = CPUTicks()
        var count = mach_msg_type_number_t(0)
        var array: processor_info_array_t?
        var arrayCount = mach_msg_type_number_t(0)

        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &count, &array, &arrayCount) == KERN_SUCCESS,
              let array else { return ticks }

        for index in 0..<Int(count) {
            let pointer = UnsafeMutableRawPointer(array)
                .advanced(by: index * MemoryLayout<processor_cpu_load_info>.size)
                .assumingMemoryBound(to: processor_cpu_load_info.self)
            let cpuTicks = pointer.pointee.cpu_ticks
            ticks.perCore.append([Int(cpuTicks.0), Int(cpuTicks.1), Int(cpuTicks.2), Int(cpuTicks.3)])
        }

        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: array),
                      vm_size_t(arrayCount) * vm_size_t(MemoryLayout<natural_t>.size))
        return ticks
    }
}

/// CPU 指标提供者：自己维护差分基准，采样失败返回「不可用」。
public struct CPUProviderImpl: MetricProvider {
    public typealias Output = CPULoad

    /// 读到的拓扑（读不到就是 nil → 不分组，绝不猜）。
    public let topology: CoreTopology?
    private var tracker = CPUBusyTracker()

    public init(topology: CoreTopology? = CoreTopologyReader.read()) {
        self.topology = topology
    }

    /// 每个逻辑核的核型（拓扑读不到时为空数组）。
    public var kinds: [CoreKind] { topology?.kindOfLogicalCPU ?? [] }

    public mutating func sample() -> Metric<CPULoad> {
        let ticks = MachCPUSampler.readTicks()
        guard !ticks.perCore.isEmpty else {
            return .unavailable(.backendUnavailable("host_processor_info 未返回数据"))
        }
        guard let busy = tracker.update(with: ticks) else {
            // 第一帧：先取一次基准，下一帧才有百分比。这是正常情况，不是故障。
            return .unavailable(.detecting)
        }
        return .value(CPULoad(total: busy.total, perCore: busy.perCore, coreKinds: kinds))
    }
}
