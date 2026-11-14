import Foundation
import VitalsCore

/// 采样层单元测试（票 08）：CPU 差分、环形缓冲、平滑、历史、口径。
func registerSamplingTests() {
    // MARK: - CPU 差分算法

    test("CPU 差分：idle 之外都算忙") {
        let previous = CPUTicks(perCore: [[100, 50, 850, 0]])
        let current = CPUTicks(perCore: [[150, 70, 930, 0]])
        guard let busy = CPUBusyCalculator.busyPercent(current: current, previous: previous) else {
            throw TestFailure(message: "应当算出占用")
        }
        // du=50 ds=20 di=80 dn=0 → busy = 70 / 150
        try expectClose(busy.perCore[0], 70.0 / 150.0 * 100, tolerance: 0.001)
        try expectClose(busy.total, 70.0 / 150.0 * 100, tolerance: 0.001)
    }

    test("CPU 差分：nice 也算忙") {
        let previous = CPUTicks(perCore: [[0, 0, 100, 0]])
        let current = CPUTicks(perCore: [[0, 0, 100, 50]])
        guard let busy = CPUBusyCalculator.busyPercent(current: current, previous: previous) else {
            throw TestFailure(message: "应当算出占用")
        }
        try expectClose(busy.perCore[0], 50.0 / 50.0 * 100, tolerance: 0.001)
    }

    test("CPU 差分：计数回绕/重置判为不可比") {
        let previous = CPUTicks(perCore: [[1000, 1000, 1000, 0]])
        let current = CPUTicks(perCore: [[10, 10, 10, 0]])
        try expect(CPUBusyCalculator.busyPercent(current: current, previous: previous) == nil)
    }

    test("CPU 差分：核数不一致时不可比") {
        let previous = CPUTicks(perCore: [[1, 1, 1, 0]])
        let current = CPUTicks(perCore: [[1, 1, 1, 0], [1, 1, 1, 0]])
        try expect(CPUBusyCalculator.busyPercent(current: current, previous: previous) == nil)
    }

    test("CPU tracker：第一帧没有基准，第二帧才有值") {
        var tracker = CPUBusyTracker()
        try expect(tracker.update(with: CPUTicks(perCore: [[1, 1, 8, 0]])) == nil)
        let value = tracker.update(with: CPUTicks(perCore: [[2, 2, 16, 0]]))
        try expect(value != nil)
        try expectClose(value!.total, 20.0, tolerance: 0.001)
    }

    test("tick 比例是 100/s") {
        try expectEqual(CPUBusyCalculator.tickScalePerSecond, 100.0)
    }

    // MARK: - 环形缓冲与平滑

    test("环形缓冲按容量淘汰最旧的") {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...5 { buffer.append(value) }
        try expectEqual(buffer.count, 3)
        try expectEqual(buffer.values, [3, 4, 5])
        try expectEqual(buffer.latest, 5)
        try expectEqual(buffer.oldest, 3)
    }

    test("环形缓冲容量至少为 1") {
        var buffer = RingBuffer<Int>(capacity: 0)
        buffer.append(7)
        try expectEqual(buffer.values, [7])
    }

    test("3 点滑动平均") {
        var average = MovingAverage3()
        try expectClose(average.push(10), 10, tolerance: 0.001)
        try expectClose(average.push(20), 15, tolerance: 0.001)
        try expectClose(average.push(30), 20, tolerance: 0.001)
        try expectClose(average.push(40), 30, tolerance: 0.001)
    }

    // MARK: - 历史

    test("历史：每核一条 60 秒曲线") {
        var store = HistoryStore(coreCount: 12)
        for _ in 0..<70 {
            store.push(perCore: Array(repeating: 10, count: 12))
        }
        try expectEqual(store.series(forCore: 0).count, 60)
        try expectEqual(store.series(forCore: 11).count, 60)
        try expectEqual(store.series(forCore: 99).count, 0)
    }

    test("历史：粗粒度每 10 秒一个点") {
        var store = HistoryStore(coreCount: 2)
        for _ in 0..<100 { store.push(perCore: [5, 5]) }
        // 100 帧 / 每 10 帧一个粗粒度点
        try expectEqual(store.coarseSeries.count, 10)
        try expectClose(store.coarseSeries.last ?? 0, 5, tolerance: 0.001)
    }

    // MARK: - 指标口径

    test("内存百分比按已用/总量算") {
        let usage = MemoryUsage(usedBytes: 10, totalBytes: 16, pressure: .normal, swapUsedBytes: 0)
        try expectClose(usage.usedPercent, 62.5, tolerance: 0.001)
    }

    test("内存总量为 0 时不崩") {
        let usage = MemoryUsage(usedBytes: 0, totalBytes: 0, pressure: .normal, swapUsedBytes: 0)
        try expectEqual(usage.usedPercent, 0)
    }

    test("温度合理区间是 0…120 °C") {
        try expect(TemperatureProviderImpl.validRange.contains(56.8))
        try expect(TemperatureProviderImpl.validRange.contains(0))
        try expect(TemperatureProviderImpl.validRange.contains(120))
        try expect(!TemperatureProviderImpl.validRange.contains(-1))
        try expect(!TemperatureProviderImpl.validRange.contains(121))
    }

    test("核心温度降级链从 Tp0j 开始") {
        try expectEqual(TemperatureProviderImpl.coreKeyChain.first, "Tp0j")
        try expectEqual(TemperatureProviderImpl.socKey, "TVD0")
        // 降级链里不能出现被禁用的键族
        for key in TemperatureProviderImpl.coreKeyChain {
            try expect(!key.hasPrefix("Tg"), "降级链里不该有 GPU 键 \(key)")
            try expect(!key.hasPrefix("TVD"), "降级链里不该有 SoC 热点键 \(key)")
            try expect(!key.hasPrefix("TH0"), "降级链里不该有环境温度键 \(key)")
        }
    }

    test("核型按快到慢排序") {
        try expectEqual(CoreKind.kindOrder, [.superCore, .performance, .efficiency])
        try expectEqual(CoreKind.efficiency.displayName, "能效核")
        try expectEqual(CoreKind.superCore.displayName, "超频核")
        try expectEqual(CoreKind.performance.displayName, "性能核")
    }
}
