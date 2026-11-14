import Foundation

/// 采样引擎：每秒采一次，产出快照并维护历史。
///
/// 职责边界（票 10）：
/// - 采样在这里发生，UI 只读快照，**不触发采集**；
/// - 某个 provider 失败只影响它自己那一个指标（降级链在 provider 内部）；
/// - 温度后端不可用时，惰性探测在后台跑一次，探测期间温度显示「不可用（正在识别…）」。
public final class MetricsEngine {

    public struct Configuration {
        public var interval: TimeInterval = 1.0
        /// 温度连续多少次读不到才触发惰性探测。
        public var temperatureFailureThreshold = 3

        public init() {}
    }

    // MARK: - 状态

    public private(set) var snapshot: CoreSnapshot = .empty
    public private(set) var history = HistoryStore(coreCount: 0)
    /// 每核的平滑读数（菜单栏用；**告警用原始值**）。
    public private(set) var smoothedCoreLoad: [Double] = []
    public private(set) var smoothedTotalLoad: Double = 0
    /// 温度探测是否正在进行。
    public private(set) var isProbingTemperature = false
    /// 每个逻辑核的核型（拓扑读不到时为空 → 不分组）。
    public var coreKinds: [CoreKind] { cpuProvider.kinds }

    /// 每次采样完成后的回调（主线程）。
    public var onUpdate: ((CoreSnapshot) -> Void)?

    private let configuration: Configuration
    private var timer: Timer?
    private var cpuProvider = CPUProviderImpl()
    private let memoryProvider = MemoryProviderImpl()
    private let powerProvider = PowerProviderImpl()
    private let thermalProvider = ThermalStateProviderImpl()
    private var temperatureProvider: TemperatureProviderImpl
    private var socProvider = SoCHotspotProviderImpl()
    private var smoothers: [MovingAverage3] = []
    private var temperatureFailures = 0
    private let probeCache = TemperatureProbeCache()
    private let lock = NSLock()

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.temperatureProvider = TemperatureProviderImpl(probedCoreKey: probeCache.load())
    }

    // MARK: - 生命周期

    public func start() {
        stop()
        let timer = Timer(timeInterval: configuration.interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()   // 立即采一次，别让界面空着等一秒
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 采样

    private func tick() {
        lock.lock()
        defer { lock.unlock() }

        var current = CoreSnapshot.empty

        // CPU：需要两次 tick 才有百分比，第一帧显示「正在识别…」。
        let cpuMetric = cpuProvider.sample()
        current.cpu = cpuMetric
        if case let .value(load, _, _) = cpuMetric {
            if history.perCore.count != load.perCore.count {
                history = HistoryStore(coreCount: load.perCore.count)
                smoothers = load.perCore.map { _ in MovingAverage3() }
            }
            history.push(perCore: load.perCore)
            smoothedCoreLoad = []
            for (index, value) in load.perCore.enumerated() where index < smoothers.count {
                smoothedCoreLoad.append(smoothers[index].push(value))
            }
            smoothedTotalLoad = smoothers.isEmpty ? load.total : load.total
        }

        current.memory = memoryProvider.sample()
        current.power = powerProvider.sample()
        current.thermalState = thermalProvider.sample()

        let temperature = temperatureProvider.sample()
        current.socHotspot = socProvider.sample()

        if temperature.isAvailable {
            temperatureFailures = 0
            current.coreTemperature = temperature
        } else {
            temperatureFailures += 1
            if temperatureFailures >= configuration.temperatureFailureThreshold, !isProbingTemperature {
                startTemperatureProbe()
            }
            current.coreTemperature = isProbingTemperature ? .unavailable(.detecting) : temperature
        }

        snapshot = current
        onUpdate?(current)
    }

    /// 惰性探测：后台跑一次，认出 CPU die 温度键并缓存。
    private func startTemperatureProbe() {
        isProbingTemperature = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var probedKey: String?
            if let session = try? SMCSession() {
                probedKey = TemperatureProbe.run(session: session)?.key
            }
            self.lock.lock()
            if let probedKey {
                self.temperatureProvider = TemperatureProviderImpl(probedCoreKey: probedKey)
                self.probeCache.save(key: probedKey)
            }
            self.isProbingTemperature = false
            self.lock.unlock()
        }
    }
}
