import AppKit
import SwiftUI
import VitalsCore
import VitalsUI

/// App 壳：菜单栏图标 + 无边框悬浮窗。
///
/// 这一层只负责外壳：状态栏、窗口、菜单，以及把采样引擎的快照喂给 VitalsUI。
/// 采样在 `VitalsCore.MetricsEngine` 里（1 Hz tick），UI 只读快照。
@main
struct VitalsAppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // LSUIElement 已在 Info.plist 里声明；这里再设一次，保证直接跑二进制时也不进 Dock。
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panelWindow: NSWindow?
    private let engine = MetricsEngine()
    private let model = PanelViewModel()
    private var panelHosting: NSHostingView<VitalsPanel>?
    private let alertCoordinator = AlertCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.backgroundOpacity = Settings.shared.backgroundOpacity
        alertCoordinator.apply(settings: Settings.shared.alertSettings)
        alertCoordinator.requestAuthorization()
        alertCoordinator.onAlert = { [weak self] alert in
            self?.model.latestAlert = alert
        }

        engine.onUpdate = { [weak self] snapshot in
            guard let self else { return }
            self.alertCoordinator.evaluate(snapshot)
            self.model.update(snapshot: snapshot,
                              history: self.engine.history,
                              kinds: self.engine.coreKinds,
                              probing: self.engine.isProbingTemperature)
            self.refreshStatusItem()
        }
        engine.start()

        makeStatusItem()
        makePanelWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    // MARK: - 菜单栏

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Vitals")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示悬浮窗", action: #selector(togglePanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "隐藏悬浮窗", action: #selector(hidePanel), keyEquivalent: ""))
        menu.addItem(.separator())

        // 透明度滑块（票 25）：20%–100%，只作用于背景，文字始终不透明。
        let opacityItem = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
        let slider = NSSlider(value: Settings.shared.backgroundOpacity,
                              minValue: 0.2, maxValue: 1.0, target: self, action: #selector(opacityChanged(_:)))
        slider.frame = NSRect(x: 0, y: 0, width: 140, height: 20)
        let sliderItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        sliderItem.view = slider
        opacityItem.submenu = NSMenu()
        opacityItem.submenu?.addItem(sliderItem)
        menu.addItem(opacityItem)

        menu.addItem(.separator())

        // 告警开关
        let alertItem = NSMenuItem(title: "启用告警", action: #selector(toggleAlerts), keyEquivalent: "")
        alertItem.state = Settings.shared.alertEnabled ? .on : .off
        menu.addItem(alertItem)

        // 阈值子菜单
        menu.addItem(thresholdMenu(title: "温度阈值",
                                   values: [70, 75, 80, 85, 90],
                                   current: Settings.shared.temperatureThreshold,
                                   action: #selector(setTemperatureThreshold(_:))))
        menu.addItem(thresholdMenu(title: "CPU 阈值",
                                   values: [80, 85, 90, 95],
                                   current: Settings.shared.cpuThreshold,
                                   action: #selector(setCPUThreshold(_:))))
        menu.addItem(NSMenuItem(title: "退出 Vitals", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }

        item.menu = menu
        statusItem = item
    }

    /// 菜单栏迷你读数：CPU% + 核心温度 + 内存%（票 11）。
    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let cpu = engine.snapshot.cpu.value.map { VitalsFormat.percent($0.total) } ?? "—"
        let memory = engine.snapshot.memory.value.map { VitalsFormat.percent($0.usedPercent) } ?? "—"
        let temperature: String
        if let reading = engine.snapshot.coreTemperature.value {
            temperature = VitalsFormat.celsiusCompact(reading.celsius)
        } else {
            temperature = "—"
        }
        button.title = "  \(cpu) · \(temperature) · \(memory)  "
    }

    @objc private func togglePanel() {
        if panelWindow?.isVisible == true { hidePanel() } else { showPanel() }
    }

    @objc private func hidePanel() {
        panelWindow?.orderOut(nil)
    }

    private func showPanel() {
        panelWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        Settings.shared.backgroundOpacity = sender.doubleValue
        model.backgroundOpacity = sender.doubleValue
    }

    /// 造一个带若干档位的阈值子菜单。
    private func thresholdMenu(title: String, values: [Double], current: Double, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for value in values {
            let entry = NSMenuItem(title: "\(Int(value))", action: action, keyEquivalent: "")
            entry.target = self
            entry.state = (value == current) ? .on : .off
            entry.representedObject = value
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    @objc private func toggleAlerts() {
        Settings.shared.alertEnabled.toggle()
        alertCoordinator.apply(settings: Settings.shared.alertSettings)
        rebuildMenu()
    }

    @objc private func setTemperatureThreshold(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        Settings.shared.temperatureThreshold = value
        alertCoordinator.apply(settings: Settings.shared.alertSettings)
        rebuildMenu()
    }

    @objc private func setCPUThreshold(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        Settings.shared.cpuThreshold = value
        alertCoordinator.apply(settings: Settings.shared.alertSettings)
        rebuildMenu()
    }

    /// 重建菜单（勾选状态变了要刷新）。
    private func rebuildMenu() {
        guard let statusItem else { return }
        makeStatusItem()
        statusItem.menu = statusItem.menu
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 悬浮窗

    private func makePanelWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.minSize = NSSize(width: 230, height: 34)
        window.maxSize = NSSize(width: 4000, height: 3000)

        let hosting = NSHostingView(rootView: VitalsPanel(model: model))
        hosting.frame = window.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting

        // 默认位置：屏幕左下角，但避开 Dock（visibleFrame 已排除）与桌面小组件区（左上）。
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window.setFrameOrigin(NSPoint(x: frame.minX + 24, y: frame.minY + 120))
        window.makeKeyAndOrderFront(nil)

        panelWindow = window
        panelHosting = hosting
    }
}

/// 用户设置（目前只有透明度；阈值与告警开关在票 13 落地）。
final class Settings {
    static let shared = Settings()

    private enum Key {
        static let backgroundOpacity = "backgroundOpacity"
        static let alertEnabled = "alertEnabled"
        static let temperatureThreshold = "temperatureThreshold"
        static let cpuThreshold = "cpuThreshold"
    }

    private let defaults = UserDefaults.standard

    /// 背景透明度 0.2…1.0（票 25：默认 100%）。
    var backgroundOpacity: Double {
        get {
            let stored = defaults.double(forKey: Key.backgroundOpacity)
            return stored <= 0 ? 1.0 : min(max(stored, 0.2), 1.0)
        }
        set {
            defaults.set(newValue, forKey: Key.backgroundOpacity)
        }
    }

    /// 告警总开关。
    var alertEnabled: Bool {
        get { defaults.object(forKey: Key.alertEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.alertEnabled) }
    }

    /// 温度阈值（°C）。
    var temperatureThreshold: Double {
        get {
            let stored = defaults.double(forKey: Key.temperatureThreshold)
            return stored <= 0 ? 80 : stored
        }
        set { defaults.set(newValue, forKey: Key.temperatureThreshold) }
    }

    /// CPU 占用阈值（%）。
    var cpuThreshold: Double {
        get {
            let stored = defaults.double(forKey: Key.cpuThreshold)
            return stored <= 0 ? 90 : stored
        }
        set { defaults.set(newValue, forKey: Key.cpuThreshold) }
    }

    /// 当前告警设置。
    var alertSettings: AlertSettings {
        AlertSettings(enabled: alertEnabled,
                      temperatureThreshold: temperatureThreshold,
                      cpuThreshold: cpuThreshold)
    }
}
