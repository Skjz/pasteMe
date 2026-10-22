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
