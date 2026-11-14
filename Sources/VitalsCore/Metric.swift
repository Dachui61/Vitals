import Foundation

/// 一个指标的读数：要么有值（可能带可信度与来源），要么明确不可用并带原因。
///
/// 按 `GLOSSARY.md`：**不可用**与「读数为 0」严格区分，任何后端失败都必须走 `.unavailable`，
/// 绝不能用一个占位的 0 冒充读数。
public enum Metric<Value> {
    case value(Value, confidence: Confidence = .measured, source: String? = nil)
    case unavailable(UnavailableReason)
    public var value: Value? {
        if case let .value(v, _, _) = self { return v }
        return nil
    }

    public var isAvailable: Bool {
        if case .value = self { return true }
        return false
    }

    public var confidence: Confidence? {
        if case let .value(_, c, _) = self { return c }
        return nil
    }

    /// 传感器名（如 `SMC Tp0j`）。界面必须把它显示出来，而不是只给一个数字。
    public var source: String? {
        if case let .value(_, _, s) = self { return s }
        return nil
    }

    public var unavailableReason: UnavailableReason? {
        if case let .unavailable(r) = self { return r }
        return nil
    }

    public func map<T>(_ transform: (Value) -> T) -> Metric<T> {
        switch self {
        case let .value(v, c, s):
            return .value(transform(v), confidence: c, source: s)
        case let .unavailable(r):
            return .unavailable(r)
        }
    }
}

/// 读数的可信度。`approximate` 对应界面上的「近似值」标注。
public enum Confidence: Equatable, Sendable {
    /// 直接测量。
    case measured
    /// 由其它信号推断（例如 SMC 键语义靠负载相关性确定）。
    case approximate
}

/// 不可用的原因。界面要显示它，而不是空白。
public enum UnavailableReason: Equatable, Sendable {
    /// 后端本身不可用（例如 dlopen 失败、权限不足）。
    case backendUnavailable(String)
    /// 系统或机型不提供这个指标。
    case unsupported
    /// 后端可用但暂时没有读到有效值（例如键不存在、读数越界）。
    case notDetected
    /// 正在探测/识别中（例如惰性探测温度传感器）。
    case detecting

    public var description: String {
        switch self {
        case let .backendUnavailable(detail):
            return detail
        case .unsupported:
            return "系统未提供该指标"
        case .notDetected:
            return "未检测到有效读数"
        case .detecting:
            return "正在识别…"
        }
    }
}

// 值类型可比时，测量值也可比——快照的相等性测试依赖它。
extension Metric: Equatable where Value: Equatable {}

// 值类型可跨并发边界时，测量值也可——快照要跨 actor 传递（票 10）。
extension Metric: Sendable where Value: Sendable {}
