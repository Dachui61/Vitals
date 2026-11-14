import Foundation
import VitalsCore

// MARK: - 骨架阶段的冒烟测试
//
// 证明分层与测试工具链是通的；票 08/09 会在这里补上真正的算法测试
// （CPU 差分、速率计算、格式化边界、核型映射）。

test("Metric 携带可信度与传感器名") {
    let m: Metric<Double> = .value(57.6, confidence: .approximate, source: "SMC Tp0j")
    try expectEqual(m.value, 57.6)
    try expectEqual(m.confidence, .approximate)
    try expectEqual(m.source, "SMC Tp0j")
    try expect(m.isAvailable)
}

test("不可用与 0 严格区分") {
    let m: Metric<Double> = .unavailable(.notDetected)
    try expect(m.value == nil)
    try expect(!m.isAvailable)
    try expectEqual(m.unavailableReason, .notDetected)
}

test("map 保留可信度、来源与不可用原因") {
    let ok: Metric<Int> = .value(2, confidence: .approximate, source: "x")
    let mapped = ok.map { $0 * 3 }
    try expectEqual(mapped.value, 6)
    try expectEqual(mapped.confidence, .approximate)
    try expectEqual(mapped.source, "x")

    let bad: Metric<Int> = .unavailable(.unsupported)
    try expect(bad.map { $0 * 3 }.value == nil)
    try expectEqual(bad.map { $0 * 3 }.unavailableReason, .unsupported)
}

test("核型分组") {
    let load = CPULoad(
        total: 20,
        perCore: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],
        coreKinds: Array(repeating: .efficiency, count: 6)
            + Array(repeating: .superCore, count: 2)
            + Array(repeating: .performance, count: 4)
    )
    try expectEqual(load.grouped(.efficiency), [1, 2, 3, 4, 5, 6])
    try expectEqual(load.grouped(.superCore), [7, 8])
    try expectEqual(load.grouped(.performance), [9, 10, 11, 12])
}

test("格式化") {
    try expectEqual(VitalsFormat.percent(63.4), "63%")
    try expectEqual(VitalsFormat.percent(63.4, decimals: 1), "63.4%")
    try expectEqual(VitalsFormat.celsius(57.63), "57.6 °C")
    try expectEqual(VitalsFormat.celsiusCompact(57.63), "58°")
    try expectEqual(VitalsFormat.bytes(16 * 1024 * 1024 * 1024), "16.0 GB")
}

test("内存百分比口径") {
    let m = MemoryUsage(
        usedBytes: 10 * 1024 * 1024 * 1024,
        totalBytes: 16 * 1024 * 1024 * 1024,
        pressure: .normal,
        swapUsedBytes: 0
    )
    try expectClose(m.usedPercent, 62.5, tolerance: 0.01)
}

exit(Int32(runAllTests()))
