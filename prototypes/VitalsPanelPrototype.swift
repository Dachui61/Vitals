// VitalsPanelPrototype.swift — 票 05：悬浮窗视觉与布局原型（第 2 版）
//
// 目的：不是好看，是把"长什么样"变成可以指着看的东西。
// 假数据驱动，覆盖四种状态变体：正常 / 温度告警 / 温度不可用 / 传感器识别中。
// 第 2 版按评审意见改了：加 v2 区块（GPU/磁盘/网络/进程 Top 5）、主题跟随系统、窗口可缩放自适应。
//
// 构建：见 prototypes/build.sh

import SwiftUI
import AppKit
import Combine

// MARK: - 状态变体

enum Variant: String, CaseIterable, Identifiable {
    case normal = "正常"
    case alert = "温度告警"
    case unavailable = "温度不可用"
    case probing = "传感器识别中"

    var id: String { rawValue }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system = "跟随系统"
    case light = "浅色"
    case dark = "深色"

    var id: String { rawValue }
}

// MARK: - 核型（票 03 实测：0–5 能效、6–7 超频、8–11 性能）

enum CoreKind: Int, CaseIterable, Identifiable {
    case superCore, perfCore, effCore

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .superCore: return "超频核"
        case .perfCore: return "性能核"
        case .effCore: return "能效核"
        }
    }
    var color: Color {
        switch self {
        case .superCore: return Color(red: 1.00, green: 0.42, blue: 0.29)
        case .perfCore: return Color(red: 0.29, green: 0.62, blue: 1.00)
        case .effCore: return Color(red: 0.24, green: 0.84, blue: 0.55)
        }
    }
    var count: Int {
        switch self {
        case .superCore: return 2
        case .perfCore: return 4
        case .effCore: return 6
        }
    }
    /// 逻辑核下标（设备树 cluster-type 实测映射）
    var indices: [Int] {
        switch self {
        case .superCore: return [6, 7]
        case .perfCore: return [8, 9, 10, 11]
        case .effCore: return [0, 1, 2, 3, 4, 5]
        }
    }
}

// MARK: - 主题（跟随系统浅/深）

struct Theme {
    let bg: Color
    let card: Color
    let stroke: Color
    let primaryText: Color
    let secondaryText: Color
    let warnYellow: Color
    let warnRed: Color

    static func of(_ scheme: ColorScheme) -> Theme {
        switch scheme {
        case .dark:
            return Theme(
                bg: Color(red: 0.09, green: 0.09, blue: 0.11),
                card: Color(red: 0.14, green: 0.14, blue: 0.17),
                stroke: Color.white.opacity(0.07),
                primaryText: Color.white.opacity(0.92),
                secondaryText: Color.white.opacity(0.48),
                warnYellow: Color(red: 1.00, green: 0.76, blue: 0.25),
                warnRed: Color(red: 1.00, green: 0.33, blue: 0.33)
            )
        default:
            return Theme(
                bg: Color(red: 0.94, green: 0.94, blue: 0.96),
                card: Color.white,
                stroke: Color.black.opacity(0.08),
                primaryText: Color.black.opacity(0.88),
                secondaryText: Color.black.opacity(0.45),
                warnYellow: Color(red: 0.85, green: 0.60, blue: 0.05),
                warnRed: Color(red: 0.85, green: 0.20, blue: 0.20)
            )
        }
    }
}

// MARK: - 假数据

struct ProcRow: Identifiable {
    let id = UUID()
    let name: String
    let cpu: Double
    let memMB: Double
}

final class FakeMetrics: ObservableObject {
    @Published var variant: Variant = .normal
    @Published var appearance: Appearance = .system
    @Published var cpuTotal: Double = 14
    @Published var memoryPercent: Double = 63
    @Published var coreTemp: Double? = 56.8
    @Published var socTemp: Double? = 62.1
    @Published var thermalPressure: String = "正常"
    @Published var gpuPercent: Double = 18
    @Published var diskRead: Double = 2.4
    @Published var diskWrite: Double = 0.8
    @Published var netDown: Double = 118
    @Published var netUp: Double = 24
    @Published var processes: [ProcRow] = [
        ProcRow(name: "Safari", cpu: 12.4, memMB: 820),
        ProcRow(name: "微信", cpu: 6.1, memMB: 460),
        ProcRow(name: "Terminal", cpu: 3.8, memMB: 92),
        ProcRow(name: "node", cpu: 2.2, memMB: 310),
        ProcRow(name: "Photos", cpu: 0.9, memMB: 205)
    ]
    @Published var histories: [[Double]] = (0..<12).map { _ in
        (0..<60).map { _ in Double.random(in: 3...22) }
    }
    @Published var probing = false

    private var tick = 0.0
    private var timer: AnyCancellable?

    init() {
        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.step() }
    }

    private func step() {
        tick += 1
        let wave = sin(tick / 4.0)
        for i in 0..<12 {
            let kind = i < 6 ? CoreKind.effCore : (i < 8 ? CoreKind.superCore : CoreKind.perfCore)
            let base: Double = kind == .effCore ? 6 : (kind == .superCore ? 18 : 14)
            let v = max(0, min(100, base + wave * 6 + Double.random(in: -3...3)))
            histories[i].append(v)
            if histories[i].count > 60 { histories[i].removeFirst() }
        }
        cpuTotal = histories.reduce(0) { $0 + $1.last! } / 12.0
        memoryPercent = 63 + sin(tick / 9) * 1.5
        gpuPercent = max(0, min(100, 18 + wave * 10 + Double.random(in: -4...4)))
        diskRead = max(0, 2.4 + wave * 1.6 + Double.random(in: -0.6...0.6))
        diskWrite = max(0, 0.8 + Double.random(in: -0.4...0.5))
        netDown = max(0, 118 + wave * 60 + Double.random(in: -25...25))
        netUp = max(0, 24 + Double.random(in: -8...10))

        switch variant {
        case .normal:
            coreTemp = 56.8 + wave * 1.4
            socTemp = 62.1 + wave * 1.8
            thermalPressure = "正常"
        case .alert:
            coreTemp = 84.6 + wave * 0.8
            socTemp = 88.2 + wave * 1.0
            thermalPressure = "重度"
        case .unavailable:
            coreTemp = nil
            socTemp = nil
            thermalPressure = "正常"
        case .probing:
            coreTemp = nil
            socTemp = nil
            thermalPressure = "正常"
        }
    }
}

// MARK: - 面板

struct PanelView: View {
    @StateObject private var m = FakeMetrics()
    @Environment(\.colorScheme) private var systemScheme

    private var scheme: ColorScheme {
        switch m.appearance {
        case .system: return systemScheme
        case .light: return .light
        case .dark: return .dark
        }
    }

    private var t: Theme { Theme.of(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            statTiles
            temperatureCard
            coreCurves
            v2Row
            processCard
            thresholdScale
            prototypeControls
        }
        .padding(14)
        .frame(minWidth: 380, maxWidth: .infinity, alignment: .leading)
        .background(t.bg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .environment(\.colorScheme, scheme)
    }

    // 顶部：拖拽把手 + 标题 + 采样状态 + 关闭
    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().fill(t.secondaryText.opacity(0.5)).frame(width: 10, height: 2)
                }
            }
            Text("Vitals").font(.system(size: 13, weight: .semibold)).foregroundStyle(t.primaryText)
            Spacer()
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 5, height: 5)
                Text("1 秒刷新").font(.system(size: 10)).foregroundStyle(t.secondaryText)
            }
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(t.secondaryText)
            }
            .buttonStyle(.plain)
        }
    }

    // 四个指标瓦片
    private var statTiles: some View {
        HStack(spacing: 8) {
            tile(title: "CPU", value: String(format: "%.0f%%", m.cpuTotal), tint: t.primaryText)
            tile(title: "核心温度", value: tempShort(m.coreTemp), tint: tempTint(m.coreTemp))
            tile(title: "内存", value: String(format: "%.0f%%", m.memoryPercent), tint: t.primaryText)
            tile(title: "电源", value: "外接电源", tint: t.primaryText, small: true)
        }
    }

    private func tile(title: String, value: String, tint: Color, small: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(t.secondaryText)
            Text(value)
                .font(.system(size: small ? 12 : 17, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 8)
        .background(t.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(t.stroke, lineWidth: 1))
    }

    // 温度明细：核心温度 + SoC 热点 + 热压力等级
    private var temperatureCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("核心温度").font(.system(size: 11)).foregroundStyle(t.secondaryText)
                    if let temp = m.coreTemp {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(String(format: "%.1f", temp)).font(.system(size: 22, weight: .medium, design: .rounded))
                                .foregroundStyle(tempTint(temp))
                            Text("°C").font(.system(size: 11)).foregroundStyle(t.secondaryText)
                        }
                        Text("SMC Tp0j · 近似值").font(.system(size: 9)).foregroundStyle(t.secondaryText)
                    } else {
                        unavailableLabel
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 2) {
                    Text("SoC 热点").font(.system(size: 11)).foregroundStyle(t.secondaryText)
                    if let temp = m.socTemp {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(String(format: "%.1f", temp)).font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(tempTint(temp))
                            Text("°C").font(.system(size: 10)).foregroundStyle(t.secondaryText)
                        }
                        Text("SMC TVD0 · 近似值").font(.system(size: 9)).foregroundStyle(t.secondaryText)
                    } else {
                        Text("不可用").font(.system(size: 11)).foregroundStyle(t.secondaryText)
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "thermometer.medium").font(.system(size: 10)).foregroundStyle(t.secondaryText)
                Text("热压力等级").font(.system(size: 10)).foregroundStyle(t.secondaryText)
                Text(m.thermalPressure).font(.system(size: 10, weight: .medium)).foregroundStyle(t.primaryText)
                Spacer()
                Text("四档 · 不是度数").font(.system(size: 9)).foregroundStyle(t.secondaryText.opacity(0.7))
            }

            if m.probing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在识别温度传感器…").font(.system(size: 10)).foregroundStyle(t.secondaryText)
                }
            }
        }
        .padding(10)
        .background(t.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(t.stroke, lineWidth: 1))
    }

    private var unavailableLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("不可用").font(.system(size: 15, weight: .medium)).foregroundStyle(t.secondaryText)
            Text("macOS 未向无特权应用开放温度传感器")
                .font(.system(size: 9)).foregroundStyle(t.secondaryText.opacity(0.75))
        }
    }

    // 每核占用：12 条并排迷你曲线，按核型着色
    private var coreCurves: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("每核占用").font(.system(size: 10)).foregroundStyle(t.secondaryText)
            ForEach(CoreKind.allCases) { kind in
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(kind.color).frame(width: 7, height: 7)
                        Text(kind.title).font(.system(size: 10)).foregroundStyle(t.secondaryText)
                        Text("×\(kind.count)").font(.system(size: 9)).foregroundStyle(t.secondaryText.opacity(0.6))
                    }
                    .frame(width: 62, alignment: .leading)

                    ForEach(kind.indices, id: \.self) { idx in
                        VStack(spacing: 2) {
                            Sparkline(values: m.histories[idx], color: kind.color)
                                .frame(height: 22)
                            Text(String(format: "%.0f", m.histories[idx].last ?? 0))
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(t.secondaryText.opacity(0.8))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            Text("60 秒滚动窗口 · 颜色区分核型").font(.system(size: 9)).foregroundStyle(t.secondaryText.opacity(0.6))
        }
        .padding(10)
        .background(t.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(t.stroke, lineWidth: 1))
    }

    // v2 区块：GPU / 磁盘 / 网络
    private var v2Row: some View {
        HStack(spacing: 8) {
            miniCard(title: "GPU 占用", value: String(format: "%.0f%%", m.gpuPercent), footnote: "近似值",
                     bar: m.gpuPercent / 100, barColor: Color(red: 0.60, green: 0.45, blue: 0.95))
            miniCard(title: "磁盘", value: String(format: "%.1f / %.1f MB/s", m.diskRead, m.diskWrite),
                     footnote: "读 / 写", bar: nil, barColor: .clear)
            miniCard(title: "网络", value: String(format: "↓%.0f ↑%.0f KB/s", m.netDown, m.netUp),
                     footnote: "下行 / 上行", bar: nil, barColor: .clear)
        }
    }

    private func miniCard(title: String, value: String, footnote: String, bar: Double?, barColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundStyle(t.secondaryText)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(t.primaryText)
                .lineLimit(1).minimumScaleFactor(0.7)
            if let bar = bar {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(t.stroke).frame(height: 4)
                        Capsule().fill(barColor).frame(width: geo.size.width * CGFloat(bar), height: 4)
                    }
                }
                .frame(height: 4)
            }
            Text(footnote).font(.system(size: 9)).foregroundStyle(t.secondaryText.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 8)
        .background(t.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(t.stroke, lineWidth: 1))
    }

    // 进程 Top 5（只读、只显示当前用户的进程）
    private var processCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("进程 Top 5").font(.system(size: 10)).foregroundStyle(t.secondaryText)
                Spacer()
                Text("仅当前用户 · 只读").font(.system(size: 9)).foregroundStyle(t.secondaryText.opacity(0.7))
            }
            ForEach(m.processes) { p in
                HStack(spacing: 8) {
                    Text(p.name).font(.system(size: 11)).foregroundStyle(t.primaryText)
                        .lineLimit(1)
                    Spacer()
                    Text(String(format: "%.1f%%", p.cpu))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(t.secondaryText)
                    Text(String(format: "%.0f MB", p.memMB))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(t.secondaryText.opacity(0.75))
                        .frame(width: 62, alignment: .trailing)
                }
            }
        }
        .padding(10)
        .background(t.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(t.stroke, lineWidth: 1))
    }

    // 温度阈值色带：0–100 °C，80 °C 告警线
    private var thresholdScale: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        Color.blue.opacity(0.30).frame(width: w * 0.70)
                        t.warnYellow.opacity(0.35).frame(width: w * 0.10)
                        t.warnRed.opacity(0.40).frame(width: w * 0.20)
                    }
                    .frame(height: 8)
                    .clipShape(Capsule())

                    if let temp = m.coreTemp {
                        let x = w * CGFloat(min(max(temp, 0), 100) / 100.0)
                        Rectangle().fill(t.primaryText).frame(width: 2, height: 12).offset(x: x - 1)
                    }
                }
            }
            .frame(height: 12)

            HStack {
                Text("0 °C").font(.system(size: 8)).foregroundStyle(t.secondaryText.opacity(0.6))
                Spacer()
                Text("70").font(.system(size: 8)).foregroundStyle(t.secondaryText.opacity(0.6))
                Text("80 °C 告警").font(.system(size: 8)).foregroundStyle(t.warnYellow)
                Spacer()
                Text("100 °C").font(.system(size: 8)).foregroundStyle(t.secondaryText.opacity(0.6))
            }
        }
        .padding(10)
        .background(t.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(t.stroke, lineWidth: 1))
    }

    // 仅原型：状态与外观切换器
    private var prototypeControls: some View {
        HStack(spacing: 6) {
            Text("原型预览").font(.system(size: 9)).foregroundStyle(t.secondaryText.opacity(0.6))
            ForEach(Variant.allCases) { v in
                pill(v.rawValue, selected: m.variant == v) { m.variant = v; m.probing = (v == .probing) }
            }
            Spacer()
            ForEach(Appearance.allCases) { a in
                pill(a.rawValue, selected: m.appearance == a) { m.appearance = a }
            }
        }
    }

    private func pill(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 9))
                .foregroundStyle(selected ? Color.black.opacity(0.85) : t.secondaryText)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(selected ? Color.white.opacity(0.85) : Color.white.opacity(0.07))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func tempShort(_ temp: Double?) -> String {
        guard let temp = temp else { return "不可用" }
        return String(format: "%.0f°", temp)
    }

    private func tempTint(_ temp: Double?) -> Color {
        guard let temp = temp else { return t.secondaryText }
        if temp >= 80 { return t.warnRed }
        if temp >= 70 { return t.warnYellow }
        return t.primaryText
    }
}

// MARK: - 迷你曲线

struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let n = max(values.count - 1, 1)
                for (i, v) in values.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(n)
                    let y = geo.size.height * (1 - CGFloat(min(max(v, 0), 100) / 100.0))
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - 窗口外壳（可缩放）

@main
struct PrototypeApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 860),
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        w.level = .floating
        w.isMovableByWindowBackground = true
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = true
        w.minSize = NSSize(width: 400, height: 620)
        let hosting = NSHostingView(rootView: PanelView())
        hosting.frame = w.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        w.contentView = hosting
        w.setFrameOrigin(NSPoint(x: 120, y: 120))
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}
