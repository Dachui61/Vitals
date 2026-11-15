import AppKit
import SwiftUI

/// 窗口交互控制器：持有窗口引用，负责拖动与缩放。
///
/// 为什么不用 `@State`：SwiftPM 给库 target 加载不到 SwiftUIMacros 插件，`@State` 编不过；
/// 而 `@StateObject`（Observation 宏）是可用的，所以状态放在这里。
public final class WindowInteractionController: ObservableObject {

    /// 窗口引用（由 `WindowAccessor` 注入）。
    @Published public private(set) var window: NSWindow?

    /// 最小尺寸。
    public var minimumSize = NSSize(width: 230, height: 34)

    private var dragOrigin: NSPoint?

    public init() {}

    public func resolve(_ window: NSWindow) {
        self.window = window
    }

    /// 拖动中：按鼠标位移移动窗口。
    ///
    /// 用 `NSEvent.mouseLocation`（屏幕坐标）而不是手势的 location —— 后者在视图坐标系里，
    /// 还要做坐标转换，多显示器/缩放下容易出错。
    public func dragChanged(translation: CGSize) {
        guard let window else { return }
        if dragOrigin == nil { dragOrigin = window.frame.origin }
        guard let origin = dragOrigin else { return }
        // SwiftUI 的 translation 是视图坐标（y 向下），窗口原点在屏幕坐标（y 向上）→ y 取反。
        window.setFrameOrigin(NSPoint(x: origin.x + translation.width,
                                     y: origin.y - translation.height))
    }

    public func dragEnded() {
        dragOrigin = nil
    }

    /// 缩放中：按位移改变窗口大小（守住最小尺寸）。
    public func resizeChanged(by translation: CGSize) {
        guard let window else { return }
        let size = window.frame.size
        let newWidth = max(minimumSize.width, size.width + translation.width)
        let newHeight = max(minimumSize.height, size.height + translation.height)
        window.setContentSize(NSSize(width: newWidth, height: newHeight))
    }
}

/// 把窗口交给 SwiftUI（拿到 `NSWindow` 引用）。
///
/// 没有它就无法在视图里移动/缩放窗口 —— `NSHostingView` 会吃掉所有鼠标事件，
/// `isMovableByWindowBackground` 对 SwiftUI 内容**无效**（本项目踩过的坑）。
public struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    public init(onResolve: @escaping (NSWindow) -> Void) {
        self.onResolve = onResolve
    }

    public func makeNSView(context: Context) -> NSView {
        let view = WindowSpyView()
        view.onResolve = onResolve
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}
}

final class WindowSpyView: NSView {
    var onResolve: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onResolve?(window) }
    }
}

/// 让某个视图可以拖动整个窗口。
public struct WindowDraggable: ViewModifier {
    let controller: WindowInteractionController

    public init(controller: WindowInteractionController) {
        self.controller = controller
    }

    public func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in controller.dragChanged(translation: value.translation) }
                .onEnded { _ in controller.dragEnded() }
        )
    }
}

/// 右下角的缩放握把：拖动即改变窗口大小。
public struct ResizeGrip: View {
    let controller: WindowInteractionController

    public init(controller: WindowInteractionController) {
        self.controller = controller
    }

    public var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.28))
            .padding(4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in controller.resizeChanged(by: value.translation) }
            )
            .help("拖动调整窗口大小")
    }
}
