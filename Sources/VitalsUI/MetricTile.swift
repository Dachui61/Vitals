import SwiftUI
import VitalsCore

/// 一个指标瓦片。不可用时显示「不可用」而不是 0（GLOSSARY）。
public struct MetricTile: View {
    public let title: String
    public let text: String
    public let tint: Color
    public let theme: VitalsTheme

    public init(title: String, text: String, tint: Color, theme: VitalsTheme) {
        self.title = title
        self.text = text
        self.tint = tint
        self.theme = theme
    }

    /// 从读数构造：可用时用值，不可用时显示「不可用」。
    public init(title: String, measurement: Metric<String>, theme: VitalsTheme) {
        self.init(title: title,
                  text: measurement.value ?? "不可用",
                  tint: measurement.isAvailable ? theme.primaryText : theme.secondaryText,
                  theme: theme)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(theme.secondaryText)
            Text(text)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 8)
        .background(theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(theme.stroke, lineWidth: 1))
    }
}
