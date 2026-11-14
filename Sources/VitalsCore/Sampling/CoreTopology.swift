import Darwin
import Foundation
import IOKit

/// CPU 拓扑：每个逻辑核的核型。
public struct CoreTopology: Equatable, Sendable {
    public let kindOfLogicalCPU: [CoreKind]

    public init(kindOfLogicalCPU: [CoreKind]) {
        self.kindOfLogicalCPU = kindOfLogicalCPU
    }
}

/// 读设备树 `IODeviceTree:/cpus/cpuN@N` 的 `cluster-type`。
///
/// 这是本机**唯一**能给逻辑核下标标出核型的来源（票 03 实测）：
/// `hw.perflevelN` 只给数量不给下标，`l2perflevels` 本机不存在，affinity 不支持。
///
/// cluster-type 是 Apple 内部取值（E/P/M），靠「数量唯一配对」映射到 sysctl 的命名 perflevel：
/// 本机 E(6)↔Efficiency(6)、P(2)↔Super(2)、M(4)↔Performance(4)。
/// **匹配不上就返回 nil** —— 调用方必须降级为「不分组」，不能猜。
public enum CoreTopologyReader {

    public static func read() -> CoreTopology? {
        var namedLevels: [(name: String, count: Int)] = []
        let levelCount = sysctlValue.int("hw.nperflevels") ?? 0
        guard levelCount > 0 else { return nil }

        for level in 0..<levelCount {
            guard let count = sysctlValue.int("hw.perflevel\(level).logicalcpu"),
                  let name = sysctlValue.string("hw.perflevel\(level).name") else { return nil }
            namedLevels.append((name, count))
        }

        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return nil }

        // 设备树节点不在 kIOServicePlane 里，必须显式指定 plane 并用迭代器遍历。
        var byType: [String: [Int]] = [:]
        var iterator: io_iterator_t = 0
        let kr = "IODeviceTree".withCString { plane in
            IORegistryEntryCreateIterator(cpus, plane, UInt32(kIORegistryIterateRecursively), &iterator)
        }
        guard kr == KERN_SUCCESS else { return nil }

        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            guard let type = ioregString(entry, "cluster-type"),
                  let logicalID = ioregInt(entry, "logical-cpu-id") else { continue }
            byType[type, default: []].append(Int(logicalID))
        }
        guard !byType.isEmpty else { return nil }

        // 数量匹配：某个 cluster-type 的个数必须等于某个命名 level 的数量。
        var typeCounts = byType.mapValues(\.count)
        var levelCounts = namedLevels.map(\.count)
        guard typeCounts.count == levelCounts.count else { return nil }

        var typeToLevel: [String: String] = [:]
        var usedLevels = Set<Int>()
        for (type, count) in typeCounts {
            let candidates = namedLevels.indices.filter { levelCounts[$0] == count && !usedLevels.contains($0) }
            guard candidates.count == 1 else { continue }
            typeToLevel[type] = namedLevels[candidates[0]].name
            usedLevels.insert(candidates[0])
        }

        // 剩下的按剩余数量配对（只有唯一解时才成立）。
        let remainingTypes = typeCounts.filter { typeToLevel[$0.key] == nil }
        let remainingLevels = namedLevels.indices.filter { !usedLevels.contains($0) }
        if remainingTypes.count == remainingLevels.count, remainingTypes.count <= 1,
           let type = remainingTypes.first?.key, let level = remainingLevels.first {
            typeToLevel[type] = namedLevels[level].name
        }
        guard typeToLevel.count == typeCounts.count else { return nil }

        var kindByName: [String: CoreKind] = [
            "Super": .superCore,
            "Performance": .performance,
            "Efficiency": .efficiency
        ]

        let total = namedLevels.reduce(0) { $0 + $1.count }
        var kinds = [CoreKind?](repeating: nil, count: total)
        for (type, indices) in byType {
            guard let levelName = typeToLevel[type], let kind = kindByName[levelName] else { return nil }
            for index in indices where index < total { kinds[index] = kind }
        }
        guard kinds.allSatisfy({ $0 != nil }) else { return nil }
        return CoreTopology(kindOfLogicalCPU: kinds.map { $0! })
    }

    // MARK: - IOKit / sysctl 小工具

    static func ioregString(_ entry: io_service_t, _ key: String) -> String? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        let value = unmanaged.takeUnretainedValue()
        if let data = value as? Data {
            // cluster-type 是 CFData（2 字节 "E\0"）
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .controlCharacters)
        }
        return value as? String
    }

    static func ioregInt(_ entry: io_service_t, _ key: String) -> Int? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        let value = unmanaged.takeUnretainedValue()
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}

/// sysctl 小工具（供各处复用）。
public enum sysctlValue {
    public static func int(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    public static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
