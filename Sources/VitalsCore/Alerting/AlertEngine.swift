import Foundation

/// 告警设置（票 13）。
public struct AlertSettings: Equatable, Sendable {
    /// 总开关。
    public var enabled: Bool
    /// 温度阈值（°C）。
    public var temperatureThreshold: Double
    /// CPU 占用阈值（%）。
    public var cpuThreshold: Double
    /// CPU 需要持续超过阈值多少秒才告警。
    public var sustainedSeconds: TimeInterval
    /// 同一类告警的冷却时间。
    public var cooldownSeconds: TimeInterval

    public init(enabled: Bool = true,
                temperatureThreshold: Double = 80,
                cpuThreshold: Double = 90,
                sustainedSeconds: TimeInterval = 30,
                cooldownSeconds: TimeInterval = 600) {
        self.enabled = enabled
        self.temperatureThreshold = temperatureThreshold
        self.cpuThreshold = cpuThreshold
        self.sustainedSeconds = sustainedSeconds
        self.cooldownSeconds = cooldownSeconds
    }
}

/// 告警的类型。
public enum AlertKind: Equatable, Sendable {
    /// 温度过高（带上触发它的传感器名）。
    case temperature(celsius: Double, sensor: String?)
    /// CPU 持续过高。
    case cpu(percent: Double)
}

/// 一条告警。
public struct Alert: Equatable, Sendable {
    public let kind: AlertKind
    public let title: String
    public let body: String

    public init(kind: AlertKind, title: String, body: String) {
        self.kind = kind
        self.title = title
        self.body = body
    }
}

/// 告警判定（**纯逻辑**，可单测；通知投递在 app 层）。
///
/// 规则：
/// - 温度：取「核心温度」与「SoC 热点」中**较高且可用**的那个，≥ 阈值即告警。
///   **边沿触发**：持续高温只发一次（不刷屏）；必须先回落到阈值以下，再次冲高才会重发，
///   且仍要过了冷却期才算。
/// - CPU：≥ 阈值并**持续** `sustainedSeconds` 才告警；冷却期内不重复。
/// - **温度不可用时不触发温度告警**，但也不能当作"温度正常"——界面要说明原因（票 04 的降级契约）。
public struct AlertEngine {

    public private(set) var settings: AlertSettings

    private var cpuAboveSince: Date?
    private var cpuAlerted = false
    private var temperatureAlerted = false
    private var lastTemperatureAlert: Date?
    private var lastCPUAlert: Date?

    public init(settings: AlertSettings = AlertSettings()) {
        self.settings = settings
    }

    /// 改设置后重置状态（避免旧阈值下的"已告警"状态压住新阈值）。
    public mutating func update(settings: AlertSettings) {
        self.settings = settings
        reset()
    }

    public mutating func reset() {
        cpuAboveSince = nil
        cpuAlerted = false
        temperatureAlerted = false
        lastTemperatureAlert = nil
        lastCPUAlert = nil
    }

    /// 判定一帧快照，返回本次应当发出的告警（可能为空、可能多条）。
    public mutating func evaluate(_ snapshot: CoreSnapshot, now: Date = Date()) -> [Alert] {
        guard settings.enabled else { return [] }
        var alerts: [Alert] = []

        // 温度：取两个温度里更高的那个（SoC 热点往往更接近降频边界）。
        let candidates: [(Double, String?)] = [
            snapshot.coreTemperature.value.map { ($0.celsius, snapshot.coreTemperature.source) },
            snapshot.socHotspot.value.map { ($0.celsius, snapshot.socHotspot.source) }
        ].compactMap { $0 }

        if let hottest = candidates.max(by: { $0.0 < $1.0 }) {
            if hottest.0 >= settings.temperatureThreshold {
                let cooled = lastTemperatureAlert.map { now.timeIntervalSince($0) >= settings.cooldownSeconds } ?? true
                if !temperatureAlerted && cooled {
                    temperatureAlerted = true
                    lastTemperatureAlert = now
                    let sensor = hottest.1 ?? "温度传感器"
                    alerts.append(Alert(
                        kind: .temperature(celsius: hottest.0, sensor: hottest.1),
                        title: "温度过高",
                        body: String(format: "%@ 达到 %.1f °C（阈值 %.0f °C）", sensor, hottest.0, settings.temperatureThreshold)
                    ))
                }
            } else {
                // 回落到阈值以下 → 允许再次触发。
                temperatureAlerted = false
            }
        }
        // 温度不可用：不动 temperatureAlerted（既不触发，也不谎称正常）。

        // CPU：持续超过阈值。
        if let cpu = snapshot.cpu.value {
            if cpu.total >= settings.cpuThreshold {
                if cpuAboveSince == nil { cpuAboveSince = now }
                let sustained = now.timeIntervalSince(cpuAboveSince!) >= settings.sustainedSeconds
                let cooled = lastCPUAlert.map { now.timeIntervalSince($0) >= settings.cooldownSeconds } ?? true
                if sustained && !cpuAlerted && cooled {
                    cpuAlerted = true
                    lastCPUAlert = now
                    alerts.append(Alert(
                        kind: .cpu(percent: cpu.total),
                        title: "CPU 持续高占用",
                        body: String(format: "CPU 占用 %.0f%% 已持续 %.0f 秒（阈值 %.0f%%）",
                                    cpu.total, settings.sustainedSeconds, settings.cpuThreshold)
                    ))
                }
            } else {
                cpuAboveSince = nil
                cpuAlerted = false
            }
        }

        return alerts
    }
}
