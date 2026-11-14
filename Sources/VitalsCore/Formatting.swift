import Foundation

/// 数值格式化。界面与单测共用，避免各处各写一套。
public enum VitalsFormat {
    /// 百分比：瓦片用整数（`63%`），详情可用一位小数。
    public static func percent(_ value: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f%%", value)
    }

    /// 温度：详情用一位小数（`57.6 °C`），瓦片用整数（`58°`）。
    public static func celsius(_ value: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f", value) + " °C"
    }

    /// 瓦片里的紧凑温度写法（不带空格与 C，用于菜单栏迷你读数）。
    public static func celsiusCompact(_ value: Double) -> String {
        String(format: "%.0f°", value)
    }

    /// 字节 → 人类可读（GB / MB）。
    public static func bytes(_ value: UInt64) -> String {
        let gib = 1024.0 * 1024.0 * 1024.0
        let mib = 1024.0 * 1024.0
        let v = Double(value)
        if v >= gib { return String(format: "%.1f GB", v / gib) }
        if v >= mib { return String(format: "%.0f MB", v / mib) }
        return String(format: "%.0f KB", v / 1024.0)
    }

    /// 速率：磁盘用 MB/s，网络用 KB/s。
    public static func rate(_ bytesPerSecond: Double, unit: String) -> String {
        String(format: "%.1f %@", bytesPerSecond, unit)
    }
}
