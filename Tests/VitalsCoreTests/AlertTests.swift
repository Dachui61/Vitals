import Foundation
import VitalsCore

/// 告警判定单测（票 13）。
func registerAlertTests() {

    func snapshot(temperature: Double?, soc: Double? = nil, cpu: Double = 0) -> CoreSnapshot {
        var result = CoreSnapshot.empty
        if let temperature {
            result.coreTemperature = .value(TemperatureReading(celsius: temperature, sensor: "SMC Tp0j"),
                                            confidence: .approximate, source: "SMC Tp0j")
        }
        if let soc {
            result.socHotspot = .value(TemperatureReading(celsius: soc, sensor: "SMC TVD0"),
                                        confidence: .approximate, source: "SMC TVD0")
        }
        result.cpu = .value(CPULoad(total: cpu, perCore: [cpu], coreKinds: [.superCore]))
        return result
    }

    let start = Date(timeIntervalSince1970: 1_700_000_000)

    test("温度达到阈值触发一次告警") {
        var engine = AlertEngine(settings: AlertSettings(temperatureThreshold: 80))
        let alerts = engine.evaluate(snapshot(temperature: 85), now: start)
        try expectEqual(alerts.count, 1)
        if case let .temperature(celsius, sensor) = alerts[0].kind {
            try expectClose(celsius, 85, tolerance: 0.01)
            try expectEqual(sensor, "SMC Tp0j")
        } else {
            throw TestFailure(message: "应该是温度告警")
        }
    }

    test("冷却期内不重复告警，且持续高温只发一次（边沿触发）") {
        var engine = AlertEngine(settings: AlertSettings(temperatureThreshold: 80, cooldownSeconds: 600))
        try expectEqual(engine.evaluate(snapshot(temperature: 85), now: start).count, 1)
        try expectEqual(engine.evaluate(snapshot(temperature: 86), now: start.addingTimeInterval(60)).count, 0)
        // 即使冷却期过了，只要一直没回落到阈值以下，就不再发（不刷屏）
        try expectEqual(engine.evaluate(snapshot(temperature: 87), now: start.addingTimeInterval(700)).count, 0)
    }

    test("温度回落后再次冲高可以重发（但仍受冷却期约束）") {
        var engine = AlertEngine(settings: AlertSettings(temperatureThreshold: 80, cooldownSeconds: 600))
        try expectEqual(engine.evaluate(snapshot(temperature: 85), now: start).count, 1)
        _ = engine.evaluate(snapshot(temperature: 70), now: start.addingTimeInterval(10))
        // 冷却还没过 → 不重发
        try expectEqual(engine.evaluate(snapshot(temperature: 85), now: start.addingTimeInterval(20)).count, 0)
        // 冷却期已过 → 重发
        try expectEqual(engine.evaluate(snapshot(temperature: 85), now: start.addingTimeInterval(700)).count, 1)
    }

    test("取核心温度与 SoC 热点中更高的那个") {
        var engine = AlertEngine(settings: AlertSettings(temperatureThreshold: 80))
        let alerts = engine.evaluate(snapshot(temperature: 60, soc: 90), now: start)
        try expectEqual(alerts.count, 1)
        if case let .temperature(celsius, sensor) = alerts[0].kind {
            try expectClose(celsius, 90, tolerance: 0.01)
            try expectEqual(sensor, "SMC TVD0")
        } else {
            throw TestFailure(message: "应该是温度告警")
        }
    }

    test("温度不可用时不触发温度告警") {
        var engine = AlertEngine(settings: AlertSettings(temperatureThreshold: 80))
        try expectEqual(engine.evaluate(snapshot(temperature: nil), now: start).count, 0)
    }

    test("CPU 需要持续超过阈值才告警") {
        var engine = AlertEngine(settings: AlertSettings(cpuThreshold: 90, sustainedSeconds: 30))
        try expectEqual(engine.evaluate(snapshot(temperature: 40, cpu: 95), now: start).count, 0)
        try expectEqual(engine.evaluate(snapshot(temperature: 40, cpu: 95), now: start.addingTimeInterval(29)).count, 0)
        let alerts = engine.evaluate(snapshot(temperature: 40, cpu: 95), now: start.addingTimeInterval(30))
        try expectEqual(alerts.count, 1)
        if case let .cpu(percent) = alerts[0].kind {
            try expectClose(percent, 95, tolerance: 0.01)
        } else {
            throw TestFailure(message: "应该是 CPU 告警")
        }
    }

    test("CPU 掉回阈值以下后重新计时") {
        var engine = AlertEngine(settings: AlertSettings(cpuThreshold: 90, sustainedSeconds: 30))
        _ = engine.evaluate(snapshot(temperature: 40, cpu: 95), now: start)
        _ = engine.evaluate(snapshot(temperature: 40, cpu: 10), now: start.addingTimeInterval(20))
        try expectEqual(engine.evaluate(snapshot(temperature: 40, cpu: 95), now: start.addingTimeInterval(40)).count, 0)
        try expectEqual(engine.evaluate(snapshot(temperature: 40, cpu: 95), now: start.addingTimeInterval(70)).count, 1)
    }

    test("关掉总开关就不告警") {
        var engine = AlertEngine(settings: AlertSettings(enabled: false, temperatureThreshold: 10))
        try expectEqual(engine.evaluate(snapshot(temperature: 99), now: start).count, 0)
    }

    test("默认阈值：温度 80°C / CPU 90% / 持续 30 秒 / 冷却 10 分钟") {
        let settings = AlertSettings()
        try expectEqual(settings.temperatureThreshold, 80)
        try expectEqual(settings.cpuThreshold, 90)
        try expectEqual(settings.sustainedSeconds, 30)
        try expectEqual(settings.cooldownSeconds, 600)
        try expect(settings.enabled)
    }
}
