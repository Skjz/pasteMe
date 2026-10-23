import AppKit
import SwiftUI
import Testing
@testable import PasteMeApp

/// 面板和预览窗口之间切换键盘焦点时，两块玻璃都保持当前窗口的样子：玻璃里那层高光一直显示。
@MainActor
@Suite(.serialized) struct WindowActivityTests {
    /// 玻璃里带 `vibrantColorMatrix` 滤镜的 `CASDFLayer` 的不透明度：窗口是当前窗口时是 1，不是时是 0。
    static func highlight(of window: NSWindow) -> [Float] {
        func walk(_ layer: CALayer) -> [Float] {
            var result: [Float] = []
            if "\(type(of: layer))" == "CASDFLayer", (layer.filters ?? []).contains(where: { "\($0)".contains("vibrantColorMatrix") }) {
                result.append(layer.opacity)
            }
            return result + (layer.sublayers ?? []).flatMap(walk)
        }
        return window.contentView?.layer.map(walk) ?? []
    }

    /// 让 AppKit 处理完 key、main 的切换和通知。
    static func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    private func windows() -> (ClipPanel, AuxiliaryPanel) {
        let panel = ClipPanel()
        panel.contentView = WindowBackground.make(cornerRadius: 16, material: .popover, content: NSHostingView(rootView: Text("面板")))
        panel.setFrame(NSRect(x: 0, y: 0, width: 240, height: 120), display: true)
        let preview = AuxiliaryPanel()
        preview.setContent(Text("预览"))
        preview.setFrame(NSRect(x: 0, y: 200, width: 240, height: 120), display: true)
        panel.orderFrontRegardless()
        preview.orderFrontRegardless()
        return (panel, preview)
    }

    @Test func bothWindowsLookActiveWhicheverHasTheKeyboard() {
        guard #available(macOS 26, *) else { return }
        let (panel, preview) = windows()
        defer { panel.orderOut(nil); preview.orderOut(nil) }

        panel.makeKey()
        WindowActivity.keepActive(panel: panel, auxiliaries: [preview])
        Self.settle()
        #expect(preview.isMainWindow)
        #expect(Self.highlight(of: panel) == [1])
        #expect(Self.highlight(of: preview) == [1])

        // 点进预览：预览成为 key，面板当 main，两块玻璃都不变。
        preview.makeKey()
        WindowActivity.keepActive(panel: panel, auxiliaries: [preview])
        Self.settle()
        #expect(panel.isMainWindow)
        #expect(Self.highlight(of: panel) == [1])
        #expect(Self.highlight(of: preview) == [1])
    }

    /// 和应用里一样接上 `WindowActivity.link`，而且在 `makeKey()` 返回时就已经切好：中间要是有一轮事件循环里
    /// 两个窗口有一个既不是 key 也不是 main，玻璃会先暗一下再亮回来，看起来在闪。
    @Test func switchingTheKeyboardKeepsBothWindowsActiveWithoutAnInBetweenState() {
        guard #available(macOS 26, *) else { return }
        let (panel, preview) = windows()
        WindowActivity.link(panel: panel, auxiliaries: [preview])
        defer { panel.orderOut(nil); preview.orderOut(nil) }

        panel.makeKey()
        #expect(panel.isKeyWindow && preview.isMainWindow)
        Self.settle()
        #expect(panel.isKeyWindow && preview.isMainWindow)
        #expect(Self.highlight(of: panel) == [1])
        #expect(Self.highlight(of: preview) == [1])

        // 点进预览。
        preview.makeKey()
        #expect(preview.isKeyWindow && panel.isMainWindow)
        Self.settle()
        #expect(preview.isKeyWindow && panel.isMainWindow)
        #expect(Self.highlight(of: panel) == [1])
        #expect(Self.highlight(of: preview) == [1])

        // 点回面板。
        panel.makeKey()
        #expect(panel.isKeyWindow && preview.isMainWindow)
        Self.settle()
        #expect(Self.highlight(of: panel) == [1])
        #expect(Self.highlight(of: preview) == [1])
    }

    /// 没有这样做时，不是 key 的那块玻璃就去掉高光：测试确实看得出这个区别。
    @Test func withoutAMainWindowTheOtherGlassDims() {
        guard #available(macOS 26, *) else { return }
        let (panel, preview) = windows()
        defer { panel.orderOut(nil); preview.orderOut(nil) }
        panel.makeKey()
        Self.settle()
        // 面板是 key 时 AppKit 也让它当 main，预览两样都不是。
        #expect(Self.highlight(of: preview) == [0])
    }
}
