import Foundation

/// 定长环形缓冲。**纯逻辑**，可单测。
public struct RingBuffer<T> {
    private var storage: [T] = []
    private let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    public mutating func append(_ value: T) {
        storage.append(value)
        if storage.count > capacity { storage.removeFirst(storage.count - capacity) }
    }

    /// 最新的值在最后。
    public var values: [T] { storage }
    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var latest: T? { storage.last }
    public var oldest: T? { storage.first }

    public mutating func clear() { storage.removeAll(keepingCapacity: true) }
}

/// 3 点滑动平均（菜单栏用；实测能立刻贴住真值）。
///
/// **不要**用 EMA：它的滞后会让告警误触发——告警判定要用原始值。
public struct MovingAverage3 {
    private var buffer: [Double] = []

    public init() {}

    public mutating func push(_ value: Double) -> Double {
        buffer.append(value)
        if buffer.count > 3 { buffer.removeFirst() }
        return buffer.reduce(0, +) / Double(buffer.count)
    }

    public var value: Double {
        guard !buffer.isEmpty else { return 0 }
        return buffer.reduce(0, +) / Double(buffer.count)
    }
}

/// 历史缓冲组：每核一条 60 秒曲线 + 一条 10 分钟粗粒度历史。**纯逻辑**，可单测。
public struct HistoryStore {
    /// 60 秒滚动窗口（1 Hz → 60 个点）。
    public static let windowSamples = 60
    /// 10 分钟粗粒度历史（每 10 秒存一个 → 60 个点）。
    public static let coarseSamples = 60

    public private(set) var perCore: [RingBuffer<Double>] = []
    public private(set) var coarse: RingBuffer<Double> = RingBuffer(capacity: HistoryStore.coarseSamples)
    private var coarseAccumulator = 0

    public init(coreCount: Int) {
        var buffers: [RingBuffer<Double>] = []
        for _ in 0..<max(coreCount, 0) {
            buffers.append(RingBuffer<Double>(capacity: HistoryStore.windowSamples))
        }
        perCore = buffers
        coarse = RingBuffer<Double>(capacity: Self.coarseSamples)
    }

    /// 推入一帧每核占用。`coarseInterval` 到期时额外存一个粗粒度点。
    public mutating func push(perCore values: [Double], coarseInterval: Int = 10) {
        for (index, value) in values.enumerated() where index < perCore.count {
            perCore[index].append(value)
        }
        coarseAccumulator += 1
        if coarseAccumulator >= coarseInterval {
            coarseAccumulator = 0
            let average = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
            coarse.append(average)
        }
    }

    /// 某核的曲线（老 → 新）。
    public func series(forCore index: Int) -> [Double] {
        guard index >= 0, index < perCore.count else { return [] }
        return perCore[index].values
    }

    public var coarseSeries: [Double] { coarse.values }
}
