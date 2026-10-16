import AppKit

/// 菜单栏图标。暂停记录时换成带斜杠的图标，一眼就能看出当前状态。
@MainActor
enum StatusIcon {
    static let normal = symbol("doc.on.clipboard", "PasteMe")

    /// 剪贴板图标加一道斜杠。
    static let paused: NSImage? = {
        guard let base = symbol("doc.on.clipboard", "PasteMe：已暂停记录") else { return nil }
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX + 1, y: rect.maxY - 1))
            slash.line(to: NSPoint(x: rect.maxX - 1, y: rect.minY + 1))
            slash.lineCapStyle = .round
            // 先沿斜杠擦出一道空隙，再画斜杠，斜杠和原图标之间才分得清。
            NSGraphicsContext.current?.compositingOperation = .clear
            slash.lineWidth = 4
            slash.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setStroke()
            slash.lineWidth = 1.5
            slash.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = base.accessibilityDescription
        return image
    }()

    private static func symbol(_ name: String, _ description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)
    }
}
