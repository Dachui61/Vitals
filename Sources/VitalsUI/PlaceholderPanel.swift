import SwiftUI
import VitalsCore

/// 一个指标瓦片。不可用时显示「不可用」而不是 0（GLOSSARY）。
public struct MetricTile: View {
    public let title: String
    public let measurement: Metric<String>
    public let theme: VitalsTheme

    public init(title: String, measurement: Metric<String>, theme: VitalsTheme) {
        self.title = title
        self.measurement = measurement
        self.theme = theme
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(theme.secondaryText)
            Text(measurement.value ?? "不可用")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(measurement.isAvailable ? theme.primaryText : theme.secondaryText)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 8)
        .background(theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(theme.stroke, lineWidth: 1))
    }
}

/// 骨架阶段的占位面板：结构已就位，真实数据由票 08/10 接入。
public struct PlaceholderPanel: View {
    public let snapshot: CoreSnapshot
    public let backgroundOpacity: Double

    @Environment(\.colorScheme) private var colorScheme

    public init(snapshot: CoreSnapshot, backgroundOpacity: Double = 1.0) {
        self.snapshot = snapshot
        self.backgroundOpacity = backgroundOpacity
    }

    private var theme: VitalsTheme {
        VitalsTheme(colorScheme: colorScheme, backgroundOpacity: backgroundOpacity)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Vitals").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.primaryText)
                Spacer()
                Text("骨架已就绪").font(.system(size: 10)).foregroundStyle(theme.secondaryText)
            }

            HStack(spacing: 8) {
                MetricTile(
                    title: "CPU",
                    measurement: snapshot.cpu.map { VitalsFormat.percent($0.total) },
                    theme: theme
                )
                MetricTile(
                    title: "核心温度",
                    measurement: snapshot.coreTemperature.map { VitalsFormat.celsiusCompact($0.celsius) },
                    theme: theme
                )
                MetricTile(
                    title: "内存",
                    measurement: snapshot.memory.map { VitalsFormat.percent($0.usedPercent) },
                    theme: theme
                )
            }

            Text("完整面板（响应式分级、每核曲线、温度卡）在票 12 落地；真实采样在票 08/09/10。")
                .font(.system(size: 10))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 380)
        .background(theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}
