import AppKit
import PasteMeCore
import SwiftUI

/// 不激活 PasteMe 自身的浮动面板。
///
/// `.nonactivatingPanel` 让面板能接收键盘输入，同时原来的前台应用保持激活状态，
/// 这样关闭面板后直接发送 ⌘V 就会粘贴到用户原本所在的应用里。
final class ClipPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // 呼出和收起的动画由 PanelAnimator 负责，不要系统自带的窗口动画。
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 收起动画用的替身窗口，不接收任何输入。
///
/// 面板本身在收起时立即 `orderOut`，把键盘焦点还给目标应用，⌘V 不用等动画结束。
/// 面板的内容视图在收起期间搬到替身窗口里，由它滑出屏幕。不能让面板留在屏幕上自己滑出去：
/// 面板交出焦点后再放回屏幕，窗口服务器就不再更新它的位置。
final class GhostPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 管理历史面板的显示、隐藏、位置、动画和键盘操作。
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let panelHeight: CGFloat = 330
    static let margin: CGFloat = 8

    private let panel = ClipPanel()
    private let ghost = GhostPanel()
    /// 毛玻璃背景和 SwiftUI 内容。平时在面板里，收起动画期间在替身窗口里。
    private let content: NSVisualEffectView
    private let model: HistoryModel
    private var keyMonitor: Any?
    private lazy var animator = PanelAnimator(window: panel)

    private enum Phase {
        case hidden, showing, shown, hiding
    }

    private var phase = Phase.hidden

    /// 面板正在呼出或已经就位。收起动画进行中算作不可见，这时再按 ⇧⌘V 会让面板滑回来。
    var isVisible: Bool { phase == .showing || phase == .shown }
    /// 最近一次呼出面板时的前台应用，粘贴的内容会送到这里。
    private(set) var targetApp: TargetApp?

    init(model: HistoryModel) {
        self.model = model
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        content = effect
        super.init()

        let hosting = NSHostingView(rootView: HistoryView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        panel.delegate = self
    }

    /// 应用启动后调用一次，提前做好第一次呼出时才会做的准备工作。
    func prewarm() {
        animator.prepare()
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        guard !isVisible else { return }
        // 面板不激活 PasteMe，呼出前的前台应用就是目标应用。
        targetApp = NSWorkspace.shared.frontmostApplication.map {
            TargetApp(bundleID: $0.bundleIdentifier, name: $0.localizedName)
        }

        if phase == .hiding {
            // 收起动画进行到一半时再次呼出：面板接过替身窗口的位置，从那里滑回去，留在原来的屏幕上。
            panel.setFrame(ghost.frame, display: false)
            moveContent(to: panel)
            animator.window = panel
            ghost.orderOut(nil)
        } else {
            moveContent(to: panel)
            animator.window = panel
            // 出现在鼠标所在的屏幕底部。
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            guard let visible = screen?.visibleFrame else { return }
            let frame = NSRect(
                x: visible.minX + Self.margin,
                y: visible.minY + Self.margin,
                width: visible.width - Self.margin * 2,
                height: Self.panelHeight
            )
            panel.setFrame(frame, display: false)
            animator.shownFrame = frame
            animator.jump(to: 0)
        }

        phase = .showing
        model.isPanelVisible = true
        model.didShow()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        animator.animate(to: 1, spring: .show) { [weak self] in
            self?.phase = .shown
        }
    }

    /// 收起面板。面板立即离开屏幕、交出键盘焦点，由替身窗口播放收起动画。
    func hide() {
        guard isVisible else { return }
        phase = .hiding
        removeKeyMonitor()
        // orderOut 会触发 windowDidResignKey，此时已是 .hiding，不会重复收起。
        panel.orderOut(nil)
        ghost.setFrame(panel.frame, display: false)
        ghost.alphaValue = panel.alphaValue
        moveContent(to: ghost)
        ghost.orderFrontRegardless()
        animator.window = ghost
        animator.animate(to: 0, spring: .hide) { [weak self] in
            guard let self else { return }
            self.ghost.orderOut(nil)
            self.phase = .hidden
            self.model.isPanelVisible = false
        }
    }

    private func moveContent(to window: NSWindow) {
        guard content.window !== window else { return }
        content.window?.contentView = NSView()
        window.contentView = content
    }

    #if DEBUG
    func snapshotPNG() -> Data? {
        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
    #endif

    nonisolated func windowDidResignKey(_ notification: Notification) {
        // 点击其他地方时自动收起。
        MainActor.assumeIsolated { hide() }
    }

    // MARK: - 键盘

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        // 本地事件监视器总是在主线程上回调。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self.panel else { return false }
                return self.handle(event)
            }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// 处理面板上的快捷键，返回 true 表示已处理、不再交给搜索框。按键规则见 `PanelKeymap`。
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = PanelKey(
            keyCode: Int(event.keyCode),
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control),
            characters: event.characters ?? ""
        )
        let context = PanelContext(focus: model.focus, queryIsEmpty: model.query.isEmpty, canUndoDelete: model.canUndoDelete)

        switch PanelKeymap.action(for: key, in: context) {
        case .passThrough:
            return false
        case .focusSearchThenPassThrough:
            // 监视器在事件分发之前回调，这里同步换掉第一响应者，这次按键就会落进搜索框。
            if let field = searchField(in: panel.contentView) {
                panel.makeFirstResponder(field)
            }
            model.focus = .search
            return false
        case .run(let command):
            run(command)
            return true
        }
    }

    private func run(_ command: PanelCommand) {
        switch command {
        case .close:
            hide()
        case .clearSearch:
            model.query = ""
            model.reload()
            model.focus = .search
        case .moveSelection(let offset):
            model.moveSelection(by: offset)
            model.focus = .cards
        case .focus(let focus):
            model.focus = focus
        case .paste(let mode):
            model.paste(as: mode)
        case .pasteAt(let index, let mode):
            model.paste(at: index, as: mode)
        case .deleteSelected:
            model.delete()
        case .undoDelete:
            model.undoDelete()
        }
    }

    /// SwiftUI 的 `TextField` 在 macOS 上由 `NSTextField` 实现，面板里只有这一个。
    private func searchField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = searchField(in: subview) { return field }
        }
        return nil
    }
}
