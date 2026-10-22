import AppKit
import SwiftUI
import Testing
@testable import PasteMeApp

/// 窗口背景（#41）。在 macOS 26 以后的系统上跑的是玻璃那一支；之前的系统上是改动前的毛玻璃材质。
@MainActor
@Suite struct WindowBackgroundTests {
    /// 玻璃在内容下面，内容不在玻璃里（原因见 `WindowBackground.make`）。
    @Test func putsGlassBehindTheContentFromMacOS26() throws {
        guard #available(macOS 26, *) else { return }
        let content = NSView()
        let background = WindowBackground.make(cornerRadius: 16, material: .popover, content: content)
        let glass = try #require(background.subviews.first as? NSGlassEffectView)
        #expect(glass.cornerRadius == 16)
        #expect(!content.isDescendant(of: glass))
        #expect(background.subviews.last.map(content.isDescendant(of:)) == true)
    }

    @Test func contentFillsTheWindow() {
        let content = NSView()
        let window = Self.window(WindowBackground.make(cornerRadius: 16, material: .popover, content: content))
        window.setContentSize(NSSize(width: 300, height: 120))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(content.convert(content.bounds, to: nil) == NSRect(x: 0, y: 0, width: 300, height: 120))
    }

    /// 内容画到四角时，四角和背景一样是圆的。
    @Test func contentIsClippedToTheRoundedCorners() throws {
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.red.cgColor
        let background = WindowBackground.make(cornerRadius: 30, material: .popover, content: content)
        let window = Self.window(background)
        window.contentView?.layoutSubtreeIfNeeded()
        let rep = try #require(background.bitmapImageRepForCachingDisplay(in: background.bounds))
        background.cacheDisplay(in: background.bounds, to: rep)

        let corner = try #require(rep.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB))
        let center = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        #expect(corner.alphaComponent < 0.05, "左上角：\(corner)")
        #expect(center.redComponent > 0.8 && center.greenComponent < 0.5, "中间：\(center)")
        _ = window
    }

    /// 附属窗口按 SwiftUI 内容想要的大小摆放（`PinboardEditorController.open`）。
    @Test func auxiliaryPanelReportsTheSizeOfItsContent() {
        let panel = AuxiliaryPanel()
        panel.setContent(Color.clear.frame(width: 120, height: 80))
        #expect(panel.fittingSize == NSSize(width: 120, height: 80))
    }

    static func window(_ background: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = background
        return window
    }
}
