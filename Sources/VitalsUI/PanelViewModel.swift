import Combine
import Foundation
import VitalsCore

/// 面板的数据源：把采样引擎的快照与历史发布给 SwiftUI。
///
/// UI **只读**这里的数据，绝不自己触发采集（票 10 的职责边界）。
public final class PanelViewModel: ObservableObject {

    @Published public private(set) var snapshot: CoreSnapshot = .empty
    /// 每核的曲线（老 → 新），与 `coreKinds` 一一对应。
    @Published public private(set) var coreSeries: [[Double]] = []
    @Published public private(set) var coreKinds: [CoreKind] = []
    /// 温度是否正在识别中。
    @Published public private(set) var probingTemperature = false

    /// 背景透明度（20–100%，文字始终不透明；票 25）。
    @Published public var backgroundOpacity: Double = 1.0

    public init() {}

    public func update(snapshot: CoreSnapshot, history: HistoryStore, kinds: [CoreKind], probing: Bool) {
        self.snapshot = snapshot
        self.coreKinds = kinds
        self.probingTemperature = probing
        self.coreSeries = kinds.indices.map { history.series(forCore: $0) }
    }
}
