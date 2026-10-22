import AppKit
import SwiftUI

/// 面板上方弹出的小窗口：预览窗口和 Pinboard 编辑窗口。
///
/// 和面板一样不激活 PasteMe，目标应用一直在前台，关掉之后照常粘贴。可以成为 key 窗口，用来输入文字；
/// 这时面板失去键盘焦点，但不会收起（`PanelController.keyMovedAway`）。
final class AuxiliaryPanel: NSPanel {
    private let cornerRadius: CGFloat
    /// `setContent` 放进来的 SwiftUI 内容。
    private var hosting: NSView?

    init(cornerRadius: CGFloat = 14) {
        self.cornerRadius = cornerRadius
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        // 和面板一样，默认不出现在共享屏幕、录屏和截图里。
        sharingType = .none
        isReleasedWhenClosed = false
    }

    /// 放进 SwiftUI 内容，铺满窗口，背景见 `WindowBackground`。
    func setContent<Content: View>(_ view: Content) {
        let hosting = NSHostingView(rootView: view)
        self.hosting = hosting
        contentView = WindowBackground.make(cornerRadius: cornerRadius, material: .popover, content: hosting)
    }

    /// SwiftUI 内容想要的大小。
    var fittingSize: NSSize {
        hosting?.fittingSize ?? .zero
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
