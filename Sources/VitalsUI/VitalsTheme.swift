import SwiftUI
import VitalsCore

/// 界面的语义色。跟随系统浅/深，并支持背景透明度（票 25）。
///
/// **透明度只作用于背景与卡片，文字始终不透明**——所以调到 20% 数字依然清晰可读。
public struct VitalsTheme {
    public let background: Color
    public let card: Color
    public let stroke: Color
    public let primaryText: Color
    public let secondaryText: Color
    public let warnYellow: Color
    public let warnRed: Color

    public init(colorScheme: ColorScheme, backgroundOpacity: Double = 1.0) {
        switch colorScheme {
        case .dark:
            background = Color(red: 0.09, green: 0.09, blue: 0.11).opacity(backgroundOpacity)
            card = Color(red: 0.14, green: 0.14, blue: 0.17).opacity(backgroundOpacity)
            stroke = Color.white.opacity(0.07).opacity(backgroundOpacity)
            primaryText = Color.white.opacity(0.92)
            secondaryText = Color.white.opacity(0.48)
            warnYellow = Color(red: 1.00, green: 0.76, blue: 0.25)
            warnRed = Color(red: 1.00, green: 0.33, blue: 0.33)
        default:
            background = Color(red: 0.94, green: 0.94, blue: 0.96).opacity(backgroundOpacity)
            card = Color.white.opacity(backgroundOpacity)
            stroke = Color.black.opacity(0.08).opacity(backgroundOpacity)
            primaryText = Color.black.opacity(0.88)
            secondaryText = Color.black.opacity(0.45)
            warnYellow = Color(red: 0.85, green: 0.60, blue: 0.05)
            warnRed = Color(red: 0.85, green: 0.20, blue: 0.20)
        }
    }

    /// 温度着色：≥80 红色，≥70 黄色，其余主色。
    public func temperatureTint(_ celsius: Double) -> Color {
        if celsius >= 80 { return warnRed }
        if celsius >= 70 { return warnYellow }
        return primaryText
    }
}
