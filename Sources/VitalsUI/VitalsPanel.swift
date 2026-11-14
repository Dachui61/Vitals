import SwiftUI
import VitalsCore

/// 悬浮窗主面板。
///
/// **响应式分级**（票 24）：宽、高各算一个允许的最高档，取小者。
/// 高度不够就退档，不裁切内容。
///
/// 视觉规范来自票 05 的原型（`prototypes/`）；本实现去掉原型控制栏，数据改为 provider 注入。
public struct VitalsPanel: View {

    /// 分档：宽度上限 / 高度下限（= 该档内容的最小高度）。
    public enum Level: Int, Comparable {
        case compact = 0     // 一行文字
        case tiles = 1       // CPU / 核心温度 / 内存
        case powerTiles = 2  // + 电源
        case temperature = 3 // + 核心温度卡
        case processes = 4   // + 进程 Top 5（v2）
        case cores = 5       // + 每核占用

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        public static func resolve(width: CGFloat, height: CGFloat) -> Level {
            let byWidth: Int
            switch width {
            case ..<320: byWidth = 0
            case ..<520: byWidth = 1
            case ..<700: byWidth = 2
            case ..<880: byWidth = 3
            case ..<1080: byWidth = 4
            default: byWidth = 5
            }
            let byHeight: Int
            switch height {
            case ..<46: byHeight = 0
            case ..<120: byHeight = 1
            case ..<200: byHeight = 2
            case ..<400: byHeight = 3
            case ..<660: byHeight = 4
            default: byHeight = 5
            }
            return Level(rawValue: min(byWidth, byHeight)) ?? .compact
        }
    }

    @ObservedObject private var model: PanelViewModel
    @Environment(\.colorScheme) private var colorScheme

    public init(model: PanelViewModel) {
        self.model = model
    }

    private var theme: VitalsTheme {
        VitalsTheme(colorScheme: colorScheme, backgroundOpacity: model.backgroundOpacity)
    }

    public var body: some View {
        GeometryReader { geometry in
            let level = Level.resolve(width: geometry.size.width, height: geometry.size.height)
            content(level: level)
                .padding(level == .compact ? 6 : 14)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .background(theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func content(level: Level) -> some View {
        if level == .compact {
            compactLine
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    if let alert = model.latestAlert {
                        alertBanner(alert)
                    }
                    tiles
                    if level >= .powerTiles { powerTiles }
                    if level >= .temperature { temperatureCard }
                    if level >= .processes { processCard }
                    if level >= .cores { coreCurves }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - L0：一行文字

    private var compactLine: some View {
        HStack(spacing: 7) {
            inlineMetric("CPU", cpuText, theme.primaryText)
            Text("·").foregroundStyle(theme.secondaryText.opacity(0.5))
            inlineMetric("温度", temperatureShortText, temperatureTint)
            Text("·").foregroundStyle(theme.secondaryText.opacity(0.5))
            inlineMetric("内存", memoryText, theme.primaryText)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
    }

    private func inlineMetric(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(theme.secondaryText)
            Text(value).foregroundStyle(tint)
        }
    }

    // MARK: - 标题栏

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().fill(theme.secondaryText.opacity(0.5)).frame(width: 10, height: 2)
                }
            }
            Text("Vitals").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.primaryText)
            Spacer()
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 5, height: 5)
                Text("1 秒刷新").font(.system(size: 10)).foregroundStyle(theme.secondaryText)
            }
        }
    }

    /// 告警横幅（通知被拒时的兜底提示）。
    private func alertBanner(_ alert: VitalsCore.Alert) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10)).foregroundStyle(theme.warnRed)
            Text(alert.title).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.warnRed)
            Text(alert.body).font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(theme.warnRed.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - 瓦片

    private var tiles: some View {
        HStack(spacing: 8) {
            MetricTile(title: "CPU", text: cpuText, tint: theme.primaryText, theme: theme)
            MetricTile(title: "核心温度", text: temperatureShortText, tint: temperatureTint, theme: theme)
            MetricTile(title: "内存", text: memoryText, tint: theme.primaryText, theme: theme)
            MetricTile(title: "GPU 占用", text: gpuText, tint: theme.primaryText, theme: theme)
        }
    }

    private var powerTiles: some View {
        HStack(spacing: 8) {
            MetricTile(title: "电源", text: powerText, tint: theme.primaryText, theme: theme)
            MetricTile(title: "磁盘", text: diskText, tint: theme.primaryText, theme: theme)
            MetricTile(title: "网络", text: networkText, tint: theme.primaryText, theme: theme)
        }
    }

    // MARK: - 温度卡

    private var temperatureCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("核心温度").font(.system(size: 11)).foregroundStyle(theme.secondaryText)
                    if let reading = model.snapshot.coreTemperature.value {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(String(format: "%.1f", reading.celsius))
                                .font(.system(size: 22, weight: .medium, design: .rounded))
                                .foregroundStyle(theme.temperatureTint(reading.celsius))
                            Text("°C").font(.system(size: 11)).foregroundStyle(theme.secondaryText)
                        }
                        Text(sensorLabel(model.snapshot.coreTemperature))
                            .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    } else {
                        unavailableLabel
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 2) {
                    Text("SoC 热点").font(.system(size: 11)).foregroundStyle(theme.secondaryText)
                    if let reading = model.snapshot.socHotspot.value {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(String(format: "%.1f", reading.celsius))
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(theme.temperatureTint(reading.celsius))
                            Text("°C").font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                        }
                        Text(sensorLabel(model.snapshot.socHotspot))
                            .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    } else {
                        Text("不可用").font(.system(size: 11)).foregroundStyle(theme.secondaryText)
                    }
                }
            }

            // 热压力等级：独立成行，四档，不叫"温度"
            HStack(spacing: 6) {
                Image(systemName: "thermometer.medium").font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                Text("热压力等级").font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                Text(model.snapshot.thermalState.value?.rawValue ?? "不可用")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.primaryText)
                Spacer()
                Text("四档 · 不是度数").font(.system(size: 9)).foregroundStyle(theme.secondaryText.opacity(0.7))
            }

            thresholdScale

            if model.probingTemperature {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在识别温度传感器…").font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                }
            }
        }
        .padding(10)
        .background(theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(theme.stroke, lineWidth: 1))
    }

    private var unavailableLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("不可用").font(.system(size: 15, weight: .medium)).foregroundStyle(theme.secondaryText)
            Text(model.snapshot.coreTemperature.unavailableReason?.description ?? "未知原因")
                .font(.system(size: 9)).foregroundStyle(theme.secondaryText.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 传感器名 + 可信度标注（近似值必须标出来）。
    private func sensorLabel(_ metric: Metric<TemperatureReading>) -> String {
        guard let source = metric.source else { return "" }
        if metric.confidence == .approximate { return "\(source) · 近似值" }
        return source
    }

    // MARK: - 阈值色带

    private var thresholdScale: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        Color.blue.opacity(0.30).frame(width: width * 0.70)
                        theme.warnYellow.opacity(0.35).frame(width: width * 0.10)
                        theme.warnRed.opacity(0.40).frame(width: width * 0.20)
                    }
                    .frame(height: 8)
                    .clipShape(Capsule())

                    if let reading = model.snapshot.coreTemperature.value {
                        let x = width * CGFloat(min(max(reading.celsius, 0), 100) / 100.0)
                        Rectangle().fill(theme.primaryText).frame(width: 2, height: 12).offset(x: x - 1)
                    }
                }
            }
            .frame(height: 12)

            HStack {
                Text("0 °C").font(.system(size: 8)).foregroundStyle(theme.secondaryText.opacity(0.6))
                Spacer()
                Text("70").font(.system(size: 8)).foregroundStyle(theme.secondaryText.opacity(0.6))
                Text("80 °C 告警").font(.system(size: 8)).foregroundStyle(theme.warnYellow)
                Spacer()
                Text("100 °C").font(.system(size: 8)).foregroundStyle(theme.secondaryText.opacity(0.6))
            }
        }
    }

    // MARK: - 进程 Top 5（只读、只含当前用户的进程）

    private var processCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("进程 Top 5").font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                Spacer()
                Text("仅当前用户 · 只读").font(.system(size: 9)).foregroundStyle(theme.secondaryText.opacity(0.7))
            }
            if let rows = model.snapshot.processes.value {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Text(row.name).font(.system(size: 11)).foregroundStyle(theme.primaryText).lineLimit(1)
                        Spacer()
                        Text(VitalsFormat.bytes(row.residentBytes))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(theme.secondaryText.opacity(0.75))
                            .frame(width: 70, alignment: .trailing)
                    }
                }
            } else {
                Text(model.snapshot.processes.unavailableReason?.description ?? "不可用")
                    .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
            }
        }
        .padding(10)
        .background(theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(theme.stroke, lineWidth: 1))
    }

    // MARK: - 每核占用

    private var coreCurves: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("每核占用").font(.system(size: 10)).foregroundStyle(theme.secondaryText)
            ForEach(CoreKind.kindOrder, id: \.self) { kind in
                let indices = model.coreKinds.indices.filter { model.coreKinds[$0] == kind }
                if !indices.isEmpty {
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).fill(kindColor(kind)).frame(width: 7, height: 7)
                            Text(kind.displayName).font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                            Text("×\(indices.count)").font(.system(size: 9)).foregroundStyle(theme.secondaryText.opacity(0.6))
                        }
                        .frame(width: 62, alignment: .leading)

                        ForEach(indices, id: \.self) { index in
                            VStack(spacing: 2) {
                                Sparkline(values: series(for: index), color: kindColor(kind))
                                    .frame(height: 22)
                                Text(percentText(currentLoad(for: index)))
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(theme.secondaryText.opacity(0.8))
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            Text("60 秒滚动窗口 · 颜色区分核型").font(.system(size: 9)).foregroundStyle(theme.secondaryText.opacity(0.6))
        }
        .padding(10)
        .background(theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(theme.stroke, lineWidth: 1))
    }

    private func series(for index: Int) -> [Double] {
        guard index >= 0, index < model.coreSeries.count else { return [] }
        return model.coreSeries[index]
    }

    private func currentLoad(for index: Int) -> Double {
        series(for: index).last ?? 0
    }

    private func kindColor(_ kind: CoreKind) -> Color {
        switch kind {
        case .superCore: return Color(red: 1.00, green: 0.42, blue: 0.29)
        case .performance: return Color(red: 0.29, green: 0.62, blue: 1.00)
        case .efficiency: return Color(red: 0.24, green: 0.84, blue: 0.55)
        }
    }

    // MARK: - 文本

    private var cpuText: String {
        guard let load = model.snapshot.cpu.value else { return "不可用" }
        return VitalsFormat.percent(load.total)
    }

    private var memoryText: String {
        guard let memory = model.snapshot.memory.value else { return "不可用" }
        return VitalsFormat.percent(memory.usedPercent)
    }

    private var powerText: String {
        guard let power = model.snapshot.power.value else { return "不可用" }
        return power.displayName
    }

    private var gpuText: String {
        guard let gpu = model.snapshot.gpu.value else { return "不可用" }
        return "\(gpu.percent)%"
    }

    private var diskText: String {
        guard let disk = model.snapshot.disk.value else { return "不可用" }
        return String(format: "%.1f/%.1f MB/s",
                      Double(disk.bytesReadPerSecond) / 1048576,
                      Double(disk.bytesWrittenPerSecond) / 1048576)
    }

    private var networkText: String {
        guard let network = model.snapshot.network.value else { return "不可用" }
        return String(format: "↓%.0f ↑%.0f KB/s",
                      Double(network.bytesInPerSecond) / 1024,
                      Double(network.bytesOutPerSecond) / 1024)
    }

    private var temperatureShortText: String {
        guard let reading = model.snapshot.coreTemperature.value else { return "不可用" }
        return VitalsFormat.celsiusCompact(reading.celsius)
    }

    private var temperatureTint: Color {
        guard let reading = model.snapshot.coreTemperature.value else { return theme.secondaryText }
        return theme.temperatureTint(reading.celsius)
    }

    private func percentText(_ value: Double) -> String {
        String(format: "%.0f", value)
    }
}

/// 迷你曲线。
struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let count = max(values.count - 1, 1)
                for (index, value) in values.enumerated() {
                    let x = geometry.size.width * CGFloat(index) / CGFloat(count)
                    let y = geometry.size.height * (1 - CGFloat(min(max(value, 0), 100) / 100.0))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
    }
}
