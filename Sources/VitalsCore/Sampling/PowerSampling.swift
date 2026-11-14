import Darwin
import Foundation
import IOKit

/// 电源状态采样。
///
/// 本机是 Mac mini（**只有交流电、没有电池**），所以只取供电来源。
/// `IOPSCopyPowerSourcesInfo()` 在本机返回非 nil 但电源列表为空，所以走 `AppleSmartBattery` 节点。
public enum PowerSampler {

    public enum Source: Equatable, Sendable {
        case acPower
        case battery
        case noBattery
        case unknown
    }

    /// 读 `AppleSmartBattery` 的 `BatteryInstalled` / `ExternalConnected`（无特权可读，2.42 µs）。
    public static func read() -> Source {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return .unknown }
        var iterator: io_iterator_t = 0
        _ = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        let service = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        guard service != 0 else { return .unknown }
        defer { IOObjectRelease(service) }

        guard let installed = CoreTopologyReader.ioregInt(service, "BatteryInstalled"),
              let external = CoreTopologyReader.ioregInt(service, "ExternalConnected") else {
            return .unknown
        }
        if installed == 0 && external == 1 { return .acPower }
        if installed == 0 { return .noBattery }
        return .battery
    }
}

/// 电源指标提供者。
public struct PowerProviderImpl: MetricProvider {
    public typealias Output = PowerState

    public init() {}

    public func sample() -> Metric<PowerState> {
        switch PowerSampler.read() {
        case .acPower:
            return .value(PowerState(onACPower: true))
        case .battery, .noBattery:
            return .value(PowerState(onACPower: false))
        case .unknown:
            return .unavailable(.backendUnavailable("AppleSmartBattery 节点不可读"))
        }
    }
}

/// 热压力等级：系统的四档判断，**不是度数**。
public struct ThermalStateProviderImpl: MetricProvider {
    public typealias Output = ThermalState

    public init() {}

    public func sample() -> Metric<ThermalState> {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .value(.nominal)
        case .fair: return .value(.fair)
        case .serious: return .value(.serious)
        case .critical: return .value(.critical)
        @unknown default: return .unavailable(.notDetected)
        }
    }
}
