import Foundation

// MARK: - CPU

/// 核型。逻辑核下标来自设备树 `cluster-type`（票 03 实测：E=能效、P=超频、M=性能）。
public enum CoreKind: String, CaseIterable, Sendable {
    case efficiency = "E"
    case superCore = "P"
    case performance = "M"

    /// 界面上显示的名字。
    public var displayName: String {
        switch self {
        case .efficiency: return "能效核"
        case .superCore: return "超频核"
        case .performance: return "性能核"
        }
    }
}

/// CPU 占用：总量 + 每核。
public struct CPULoad: Equatable, Sendable {
    /// 总占用，0…100。
    public let total: Double
    /// 每核占用，与 `coreKinds` 一一对应。
    public let perCore: [Double]
    /// 每核的核型。
    public let coreKinds: [CoreKind]

    public init(total: Double, perCore: [Double], coreKinds: [CoreKind]) {
        self.total = total
        self.perCore = perCore
        self.coreKinds = coreKinds
    }

    /// 按核型分组后的每核占用，供界面按组着色绘制。
    public func grouped(_ kind: CoreKind) -> [Double] {
        coreKinds.enumerated().compactMap { index, k in
            k == kind && index < perCore.count ? perCore[index] : nil
        }
    }

    /// 核型分组的顺序：先超频核，再性能核，最后能效核（由快到慢）。
    public static let kindOrder: [CoreKind] = [.superCore, .performance, .efficiency]
}

// MARK: - 内存

/// 内存状态。`usedBytes` 的口径见票 03：App + Wired + Compressed，
/// **不是** `total − free − speculative`。
public struct MemoryUsage: Equatable, Sendable {
    public let usedBytes: UInt64
    public let totalBytes: UInt64
    /// 内存压力等级。
    public let pressure: MemoryPressure
    /// swap 已用字节（票 03：`vm.swapusage` 的单位是字节）。
    public let swapUsedBytes: UInt64

    public init(usedBytes: UInt64, totalBytes: UInt64, pressure: MemoryPressure, swapUsedBytes: UInt64) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.pressure = pressure
        self.swapUsedBytes = swapUsedBytes
    }

    public var usedPercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100
    }
}

/// 内存压力等级（`kern.memorystatus_vm_pressure_level` 是位掩码 1/2/4）。
public enum MemoryPressure: String, Sendable {
    case normal = "正常"
    case warn = "轻度"
    case critical = "重度"
}

// MARK: - 温度

/// 温度读数。
public struct TemperatureReading: Equatable, Sendable {
    /// 摄氏度。
    public let celsius: Double
    /// 传感器名，如 `SMC Tp0j`。
    public let sensor: String

    public init(celsius: Double, sensor: String) {
        self.celsius = celsius
        self.sensor = sensor
    }
}

/// 热压力等级：系统的四档判断，**不是度数**（GLOSSARY：绝不与温度混为一谈）。
public enum ThermalState: String, CaseIterable, Sendable {
    case nominal = "正常"
    case fair = "轻度"
    case serious = "重度"
    case critical = "关键"
}

// MARK: - 电源

/// 电源状态。本机是 Mac mini（仅交流电，无电池），所以只有供电来源。
public struct PowerState: Equatable, Sendable {
    public let onACPower: Bool

    public init(onACPower: Bool) {
        self.onACPower = onACPower
    }

    public var displayName: String {
        onACPower ? "外接电源" : "电池供电"
    }
}

// MARK: - 快照

/// 一次采样得到的全部指标。UI 只读这个结构，不直接调用任何采样器。
public struct CoreSnapshot: Equatable, Sendable {
    public var cpu: Metric<CPULoad>
    public var memory: Metric<MemoryUsage>
    public var power: Metric<PowerState>
    /// 核心温度（核心温度传感器）。
    public var coreTemperature: Metric<TemperatureReading>
    /// SoC 封装热点。
    public var socHotspot: Metric<TemperatureReading>
    /// 热压力等级。
    public var thermalState: Metric<ThermalState>

    public init(
        cpu: Metric<CPULoad> = .unavailable(.unsupported),
        memory: Metric<MemoryUsage> = .unavailable(.unsupported),
        power: Metric<PowerState> = .unavailable(.unsupported),
        coreTemperature: Metric<TemperatureReading> = .unavailable(.unsupported),
        socHotspot: Metric<TemperatureReading> = .unavailable(.unsupported),
        thermalState: Metric<ThermalState> = .unavailable(.unsupported)
    ) {
        self.cpu = cpu
        self.memory = memory
        self.power = power
        self.coreTemperature = coreTemperature
        self.socHotspot = socHotspot
        self.thermalState = thermalState
    }

    /// 全部都还拿不到的快照（启动时、探测中的过渡态）。
    public static let empty = CoreSnapshot()
}
