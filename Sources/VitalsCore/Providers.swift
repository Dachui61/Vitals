import Foundation

/// 指标提供者的公共约定。
///
/// 每个 provider 独立取数、独立失败：某个后端挂了只影响它自己那一个指标，
/// 其余指标照常显示（票 04 的降级契约）。
///
/// 实现时**不得** fork 子进程取数（票 03 实测：fork `iostat` 1075 ms、`pmset` 76 ms，
/// 1 Hz 采样完全不可接受），也不得在 provider 里抛出异常——失败一律表达成
/// `Metric.unavailable(reason)`。
public protocol MetricProvider {
    associatedtype Output

    /// 取一次读数。实现必须是廉价且无副作用的（可被 1 Hz 调度器反复调用）。
    func sample() -> Metric<Output>
}

public protocol CPUProvider: MetricProvider where Output == CPULoad {}
public protocol MemoryProvider: MetricProvider where Output == MemoryUsage {}
public protocol PowerProvider: MetricProvider where Output == PowerState {}
public protocol ThermalStateProvider: MetricProvider where Output == ThermalState {}
public protocol CoreTemperatureProvider: MetricProvider where Output == TemperatureReading {}

/// 采样器汇总：一次 tick 取齐所有指标，交给 UI。
///
/// 由票 10 落地（actor + 1s tick + 历史环形缓冲）；这里只定义契约。
public protocol SnapshotProvider {
    func snapshot() -> CoreSnapshot
}
