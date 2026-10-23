import AppKit

/// 面板、附属窗口、Paste Stack 浮窗和 Toast 的背景（#41）：macOS 26 起是 Liquid Glass（`NSGlassEffectView`），
/// 之前是毛玻璃材质（`NSVisualEffectView`）。
@MainActor
enum WindowBackground {
    /// 一块铺满 `content` 的圆角背景，给窗口当 `contentView`。
    ///
    /// - Parameter material: macOS 26 之前用的材质。
    static func make(cornerRadius: CGFloat, material: NSVisualEffectView.Material, content: NSView) -> NSView {
        if #available(macOS 26, *) {
            // 玻璃只当背景，内容叠在它上面，不放进它的 `contentView`：放进去的话，窗口每次上屏玻璃都会让内容整个重画一遍，
            // 面板的 `show()` 多花 10 ms 左右、`hide()` 多花 6 ms 左右（`scripts/bench-panel.sh` 的 `call_ms`）。
            let container = NSView()
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            fill(container, with: glass)
            // 玻璃的圆角管不到上面的内容，内容画到四角时会露出直角。内容裁成同样的圆角，和旧材质一样。
            let clip = NSView()
            clip.wantsLayer = true
            clip.layer?.cornerRadius = cornerRadius
            clip.layer?.masksToBounds = true
            fill(clip, with: content)
            fill(container, with: clip)
            return container
        }
        let effect = NSVisualEffectView()
        effect.material = material
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        fill(effect, with: content)
        return effect
    }

    private static func fill(_ container: NSView, with content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

/// 面板和上方的附属窗口（预览、Pinboard 编辑窗口）在玻璃上看起来都是当前窗口。
///
/// Liquid Glass 跟着窗口是不是当前窗口变：窗口是 key 或 main 时，玻璃里有一层高光（带 `vibrantColorMatrix`
/// 滤镜的那层），两样都不是时这层就去掉，像切到了别的应用。点预览时预览成为 key、面板不再是 key，
/// 两块玻璃同时一变，就像在两个应用的窗口之间切换。`NSGlassEffectView` 没有 `NSVisualEffectView.state`
/// 那样固定成当前窗口的开关，SwiftUI 的 `appearsActive` 也改不了它，所以借 main：谁是 key，就把另一个开着的设成 main。
/// 测试在 `WindowActivityTests`。
@MainActor
enum WindowActivity {
    /// 这几个窗口换了 key 以后调用 `keepActive`（`KeepsCompanionActive.onKeyChange`）。
    ///
    /// 时机很要紧。推迟到下一轮事件循环的话，中间那一帧有一个窗口既不是 key 也不是 main，两块玻璃先暗一下
    /// 再亮回来，看起来在闪；在「成为 key」的通知里设又太早，AppKit 发完通知还会调整 main，把它改掉。
    /// 所以在 `makeKey()`、`sendEvent(_:)` 的 `super` 返回以后设：AppKit 这次的切换做完了，屏幕还没画。
    /// 两种窗口自己是 key 时都不当 main（`canBecomeMain`），main 留给另一个。
    static func link(panel: NSWindow & KeepsCompanionActive, auxiliaries: [NSWindow & KeepsCompanionActive]) {
        let update: () -> Void = { [weak panel] in
            guard let panel else { return }
            keepActive(panel: panel, auxiliaries: auxiliaries)
        }
        panel.onKeyChange = update
        for auxiliary in auxiliaries { auxiliary.onKeyChange = update }
    }

    static func keepActive(panel: NSWindow, auxiliaries: [NSWindow]) {
        let auxiliary = auxiliaries.first(where: \.isVisible)
        let companion: NSWindow?
        if panel.isKeyWindow {
            companion = auxiliary
        } else if let auxiliary, auxiliary.isKeyWindow {
            companion = panel.isVisible ? panel : nil
        } else {
            companion = nil
        }
        // 不是 main 的才设，免得 main 的通知又绕回来。
        if let companion, !companion.isMainWindow, companion.canBecomeMain {
            companion.makeMain()
        }
    }
}

/// 面板和附属窗口：换了 key 以后（`makeKey()`、点击的 `super` 返回以后）调用 `onKeyChange`，见 `WindowActivity.link`。
@MainActor
protocol KeepsCompanionActive: AnyObject {
    var onKeyChange: () -> Void { get set }
}
