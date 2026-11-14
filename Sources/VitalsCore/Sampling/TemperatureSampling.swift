import Darwin
import Foundation

/// CPU 核心温度的后端（票 04 / 09）。
///
/// - 平时直读主键 `Tp0j`（票 23 实测：CPU 选择性最强、CPU 侧绝对温度最高）；
/// - 读不到 / 读值越界 / 长期不动 → 触发**惰性探测**（见 `TemperatureProbe`）；
/// - 键语义是"负载相关性推断"而非 Apple 确认 → 一律标 `approximate`，并把传感器名带给界面。
public struct TemperatureProviderImpl: MetricProvider {
    public typealias Output = TemperatureReading

    /// 核心温度的降级链（票 23）。
    public static let coreKeyChain = ["Tp0j", "Tp0g", "Tp09", "Tp07", "Tp0b", "Tp05", "Tp0m", "Tp0L"]
    /// SoC 封装热点（票 23：整机最热，但不是 CPU die）。
    public static let socKey = "TVD0"

    /// 合理的温度区间（°C）。超出即视为无效读数。
    public static let validRange: ClosedRange<Double> = 0...120

    private let session: SMCSession?
    private let sessionError: String?
    /// 探测出来的键（优先于默认链）。
    private let probedCoreKey: String?

    public init(session: SMCSession? = nil, probedCoreKey: String? = nil) {
        if let session {
            self.session = session
            self.sessionError = nil
        } else {
            do {
                self.session = try SMCSession()
                self.sessionError = nil
            } catch {
                self.session = nil
                self.sessionError = error.localizedDescription
            }
        }
        self.probedCoreKey = probedCoreKey
    }

    public func sample() -> Metric<TemperatureReading> {
        guard let session else {
            return .unavailable(.backendUnavailable(sessionError ?? "libSMC 不可用"))
        }

        var candidates = Self.coreKeyChain
        if let probedCoreKey { candidates.insert(probedCoreKey, at: 0) }

        for name in candidates {
            guard let value = session.read(name) else { continue }
            guard Self.validRange.contains(value) else { continue }
            return .value(TemperatureReading(celsius: value, sensor: name),
                          confidence: .approximate,
                          source: "SMC \(name)")
        }
        return .unavailable(.notDetected)
    }
}

/// SoC 封装热点。读不到就显示「不可用」——**绝不用它冒充 CPU 温度**。
public struct SoCHotspotProviderImpl: MetricProvider {
    public typealias Output = TemperatureReading

    private let session: SMCSession?
    private let sessionError: String?

    public init(session: SMCSession? = nil) {
        if let session {
            self.session = session
            self.sessionError = nil
        } else {
            do {
                self.session = try SMCSession()
                self.sessionError = nil
            } catch {
                self.session = nil
                self.sessionError = error.localizedDescription
            }
        }
    }

    public func sample() -> Metric<TemperatureReading> {
        guard let session else {
            return .unavailable(.backendUnavailable(sessionError ?? "libSMC 不可用"))
        }
        let name = TemperatureProviderImpl.socKey
        guard let value = session.read(name), TemperatureProviderImpl.validRange.contains(value) else {
            return .unavailable(.notDetected)
        }
        return .value(TemperatureReading(celsius: value, sensor: name),
                      confidence: .approximate,
                      source: "SMC \(name)")
    }
}

/// 惰性探测：识别"哪个 SMC 键才是 CPU die 温度"。
///
/// 原理（票 23 实测）：CPU 选择性最强且 CPU 侧温度最高的键就是它。
/// 所以流程是：枚举候选温度键 → 采基线 → 起 1–2 秒单线程 userInteractive 负载 → 再采一次 →
/// 取**涨幅最大**的键。注意**不能按"谁的温度高"挑**——SoC 热点绝对值更高，但 GPU 也会推高它。
public enum TemperatureProbe {

    public struct Result: Equatable, Sendable {
        public let key: String
        public let rise: Double
    }

    /// 候选：名字以 T 开头、且当前读数落在合理温度区间的键。
    public static func candidates(in session: SMCSession) -> [String] {
        let names = session.allKeyNames()
        return names.filter { name in
            guard name.first == "T" || name.first == "t" else { return false }
            guard let value = session.read(name) else { return false }
            return TemperatureProviderImpl.validRange.contains(value)
        }
    }

    /// 跑一次探测。`loadSeconds` 决定负载时长（本机 1–2 秒足够区分）。
    public static func run(session: SMCSession, loadSeconds: Double = 1.5) -> Result? {
        let candidates = candidates(in: session)
        guard candidates.count > 1 else { return nil }

        var baseline: [String: Double] = [:]
        for name in candidates {
            if let value = session.read(name) { baseline[name] = value }
        }
        guard !baseline.isEmpty else { return nil }

        // 单线程 userInteractive 负载：把 CPU 压上去，让 CPU die 的温度明显上升。
        let workload = DispatchQueue(label: "vitals.temperature.probe", qos: .userInteractive)
        let deadline = Date().addingTimeInterval(loadSeconds)
        workload.async {
            var sink = 0.0
            while Date() < deadline {
                for i in 0..<200_000 { sink += Double(i) * 0.5 }
            }
            if sink < 0 { print(sink) }
        }
        Thread.sleep(forTimeInterval: loadSeconds + 0.4)

        var best: Result?
        for (name, base) in baseline {
            guard let now = session.read(name) else { continue }
            let rise = now - base
            guard rise > 1 else { continue }   // 没被 CPU 推热的键不是 CPU die
            if best == nil || rise > best!.rise {
                best = Result(key: name, rise: rise)
            }
        }
        return best
    }
}

/// 探测结果的落盘缓存（连同机型与系统版本，换机器或升级后自动失效重探）。
public struct TemperatureProbeCache {

    public struct Entry: Codable, Equatable {
        public let key: String
        public let machine: String
        public let osVersion: String
    }

    private let url: URL?

    public init(fileName: String = "temperature-sensor.json") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("Vitals", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.url = directory.appendingPathComponent(fileName)
    }

    private static var machineIdentifier: String {
        sysctlValue.string("hw.model") ?? "unknown"
    }

    private static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// 读缓存；机型或系统版本对不上就当作没有缓存。
    public func load() -> String? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        guard let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        guard entry.machine == Self.machineIdentifier, entry.osVersion == Self.osVersion else { return nil }
        return entry.key
    }

    public func save(key: String) {
        guard let url else { return }
        let entry = Entry(key: key, machine: Self.machineIdentifier, osVersion: Self.osVersion)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: url)
    }
}
