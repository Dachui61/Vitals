import Foundation
import VitalsCore

/// 真机采样检查：直接问系统要数，打印出来。
func runLiveCheck() -> Int {
    print("Vitals 真机采样检查（\(Date())）")

    // 核型拓扑
    if let topology = CoreTopologyReader.read() {
        let groups = Dictionary(grouping: topology.kindOfLogicalCPU.indices, by: { topology.kindOfLogicalCPU[$0] })
        let summary = CoreKind.kindOrder.compactMap { kind -> String? in
            guard let indices = groups[kind] else { return nil }
            return "\(kind.displayName)=\(indices.map(String.init).joined(separator: ","))"
        }
        print("  核型映射: \(summary.joined(separator: "  "))")
    } else {
        print("  核型映射: 读不到（会降级为不分组）")
    }

    let engine = MetricsEngine()
    engine.start()
    for _ in 0..<4 {
        // 用 RunLoop 跑一秒，让引擎的 1 Hz Timer 有机会触发（直接 sleep 会占住主线程）
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        let snapshot = engine.snapshot

        let cpu: String
        switch snapshot.cpu {
        case let .value(load, _, _):
            cpu = String(format: "总 %.1f%%  每核 %@", load.total,
                         load.perCore.map { String(format: "%.0f", $0) }.joined(separator: "/"))
        case let .unavailable(reason):
            cpu = "不可用（\(reason.description)）"
        }

        let temperature: String
        switch snapshot.coreTemperature {
        case let .value(reading, confidence, source):
            temperature = String(format: "%.1f °C  来源 %@  可信度 %@",
                                 reading.celsius, source ?? "-", confidence == .approximate ? "近似值" : "实测")
        case let .unavailable(reason):
            temperature = "不可用（\(reason.description)）"
        }

        let soc: String
        switch snapshot.socHotspot {
        case let .value(reading, _, source): soc = String(format: "%.1f °C (%@)", reading.celsius, source ?? "-")
        case let .unavailable(reason): soc = "不可用（\(reason.description)）"
        }

        let memory: String
        switch snapshot.memory {
        case let .value(usage, _, _):
            memory = String(format: "%.1f / %.1f GB (%.0f%%)  压力 %@  swap %.0f MB",
                            Double(usage.usedBytes) / 1073741824,
                            Double(usage.totalBytes) / 1073741824,
                            usage.usedPercent, usage.pressure.rawValue,
                            Double(usage.swapUsedBytes) / 1048576)
        case let .unavailable(reason): memory = "不可用（\(reason.description)）"
        }

        let power: String
        switch snapshot.power {
        case let .value(state, _, _): power = state.displayName
        case let .unavailable(reason): power = "不可用（\(reason.description)）"
        }

        print("  CPU: \(cpu)")
        print("  核心温度: \(temperature)")
        print("  SoC 热点: \(soc)")
        print("  内存: \(memory)")
        print("  电源: \(power)")
        print("  热压力等级: \(snapshot.thermalState.value?.rawValue ?? "不可用")")
        print("  ---")
    }
    engine.stop()
    print("采样检查结束")
    return 0
}
