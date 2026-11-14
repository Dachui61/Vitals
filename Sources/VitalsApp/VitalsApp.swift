import AppKit
import SwiftUI
import VitalsCore
import VitalsUI

/// App 壳：菜单栏图标 + 无边框悬浮窗。
///
/// 这一层只负责"外壳"：状态栏、窗口、菜单，以及把快照喂给 VitalsUI。
/// 真实采样由票 08/09/10 接入，完整面板由票 12 落地。
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
    private var snapshot = CoreSnapshot.empty

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeStatusItem()
        makePanelWindow()
        // 骨架阶段没有真实采样器，先用空快照把界面跑起来（票 08/10 接入后替换）。
        refreshSnapshot()
    }

    // MARK: - 菜单栏

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Vitals")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示悬浮窗", action: #selector(togglePanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "设置…（阈值 / 透明度）", action: #selector(placeholder), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 Vitals", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func togglePanel() {
        if panelWindow?.isVisible == true {
            panelWindow?.orderOut(nil)
        } else {
            panelWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func placeholder() {
        NSLog("Vitals: 设置项（阈值、透明度、告警开关）由票 11/13/25 落地")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 悬浮窗

    private func makePanelWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 408, height: 150),
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

        let hosting = NSHostingView(rootView: PlaceholderPanel(snapshot: snapshot))
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

    private var panelHosting: NSHostingView<PlaceholderPanel>?

    private func refreshSnapshot() {
        // 骨架阶段：没有采样器。票 08/09/10 落地后，这里改成 1 Hz tick 拉取快照。
        let hosting = panelHosting
        guard let hosting else { return }
        hosting.rootView = PlaceholderPanel(snapshot: snapshot)
    }
}
