import AppKit
import Carbon.HIToolbox
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
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 管理历史面板的显示、隐藏、位置和键盘操作。
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let panelHeight: CGFloat = 330
    static let margin: CGFloat = 8

    private let panel = ClipPanel()
    private let model: HistoryModel
    private var keyMonitor: Any?

    var isVisible: Bool { panel.isVisible }

    init(model: HistoryModel) {
        self.model = model
        super.init()

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true

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

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
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

        model.didShow()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func hide() {
        removeKeyMonitor()
        panel.orderOut(nil)
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

    /// 处理面板上的快捷键，返回 true 表示已处理、不再交给搜索框。
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)

        switch Int(event.keyCode) {
        case kVK_Escape:
            if model.query.isEmpty {
                hide()
            } else {
                model.query = ""
                model.reload()
            }
            return true
        case kVK_LeftArrow:
            model.moveSelection(by: -1)
            return true
        case kVK_RightArrow:
            model.moveSelection(by: 1)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            model.paste(plainText: shift)
            return true
        case kVK_Delete where command:
            model.delete()
            return true
        default:
            break
        }

        if command, let index = Self.digitKeyCodes.firstIndex(of: Int(event.keyCode)) {
            model.paste(at: index, plainText: shift)
            return true
        }
        return false
    }

    /// 数字键 1…9 的键码。用键码而不是字符判断，按住 Shift 时 1 会变成 "!"。
    private static let digitKeyCodes = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]
}
