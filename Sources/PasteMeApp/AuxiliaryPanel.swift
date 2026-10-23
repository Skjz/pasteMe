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
        let hosting = FirstClickHostingView(rootView: view)
        self.hosting = hosting
        contentView = WindowBackground.make(cornerRadius: cornerRadius, material: .popover, content: hosting)
    }

    /// SwiftUI 内容想要的大小。
    var fittingSize: NSSize {
        hosting?.fittingSize ?? .zero
    }

    override var canBecomeKey: Bool { true }
    // 面板是 key 时附属窗口当 main，玻璃才保持当前窗口的样子；自己是 key 时不当，main 留给面板（`WindowActivity`）。
    override var canBecomeMain: Bool { !isKeyWindow }

    var onKeyChange: () -> Void = {}

    override func makeKey() {
        super.makeKey()
        onKeyChange()
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        onKeyChange()
    }

    /// 不是 key 时被点了一下、点完又没有控件要键盘时调用：预览把键盘还给面板，见 `sendEvent`。
    /// 为 nil 时（Pinboard 编辑窗口，它失去 key 就会关掉）不还。
    var onClickWithoutKeyboard: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        let isClick = NSWindow.clickTypes.contains(event.type)
        let wasKey = isKeyWindow
        takeKeyForFirstClick(event)
        super.sendEvent(event)
        guard isClick else { return }
        // SwiftUI 的按钮点中的是它里面不接受第一下点击的视图，窗口为了把点击交出去成为了 key。点完以后第一响应者
        // 还是窗口自己，说明没有控件要打字（正文、标题框、网页、Quick Look 会成为第一响应者），键盘还给面板，
        // 空格和 ← → 照常作用于面板。都在这一下点击里做完，玻璃不会闪（`WindowActivity`）。
        if !wasKey, isKeyWindow, firstResponder === self || firstResponder == nil, let onClickWithoutKeyboard {
            onClickWithoutKeyboard()
        }
        // 点网页这类自己让窗口成为 key 的视图：AppKit 在 `super` 里换的 key，这里补上 main。
        onKeyChange()
    }
}

extension NSWindow {
    static let clickTypes: Set<NSEvent.EventType> = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

    /// 不是 key 时的第一下点击：AppKit 默认只拿它让窗口成为 key，点到的视图收不到，要再点一下。
    /// 面板和附属窗口在 `sendEvent` 里先调用它：点到的视图本来就接受第一下点击（SwiftUI 的内容、网页、图片）时
    /// 照常交给它，窗口不抢键盘焦点；不接受的（正文、标题框、搜索框、Quick Look 里面的视图）先让窗口成为 key，
    /// 这一下点击接着交给它。
    func takeKeyForFirstClick(_ event: NSEvent) {
        guard !isKeyWindow, canBecomeKey, Self.clickTypes.contains(event.type),
              let contentView, let frameView = contentView.superview,
              // `hitTest` 要的是父视图坐标系里的点。
              let hit = contentView.hitTest(frameView.convert(event.locationInWindow, from: nil)),
              !hit.acceptsFirstMouse(for: event)
        else { return }
        makeKey()
    }
}

extension AuxiliaryPanel: KeepsCompanionActive {}

/// 面板和附属窗口里的 SwiftUI 内容：接受第一下点击，点卡片、按钮不用先让窗口成为 key（见 `takeKeyForFirstClick`）。
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
