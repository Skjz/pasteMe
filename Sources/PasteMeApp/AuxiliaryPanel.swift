import AppKit
import SwiftUI

/// 面板上方弹出的小窗口：预览窗口和 Pinboard 编辑窗口。
///
/// 和面板一样不激活 PasteMe，目标应用一直在前台，关掉之后照常粘贴。可以成为 key 窗口，用来输入文字；
/// 这时面板失去键盘焦点，但不会收起（`PanelController.keyMovedAway`）。
final class AuxiliaryPanel: NSPanel {
    init(cornerRadius: CGFloat = 14) {
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

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        contentView = effect
    }

    /// 放进 SwiftUI 内容，铺满窗口。
    func setContent<Content: View>(_ view: Content) {
        guard let effect = contentView else { return }
        effect.subviews.forEach { $0.removeFromSuperview() }
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
    }

    /// SwiftUI 内容想要的大小。
    var fittingSize: NSSize {
        contentView?.subviews.first?.fittingSize ?? .zero
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
