import AppKit
import SwiftUI
import Testing
@testable import PasteMeApp

/// 预览窗口不是 key 时，第一下点击直接交给点到的视图，不用先点一下让窗口成为 key。
@MainActor
@Suite struct FirstClickTests {
    /// 记下收到的鼠标按下。`firstMouse` 是它接不接受不是 key 的窗口里的第一下点击。
    class ClickRecorder: NSView {
        var firstMouse = false
        var clicks = 0
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { firstMouse }
        override func mouseDown(with event: NSEvent) { clicks += 1 }
    }

    private func panel(with recorder: ClickRecorder) -> AuxiliaryPanel {
        let panel = AuxiliaryPanel()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        recorder.frame = content.bounds
        content.addSubview(recorder)
        panel.contentView = content
        panel.setFrame(NSRect(x: 0, y: 0, width: 200, height: 100), display: false)
        panel.orderFrontRegardless()
        return panel
    }

    private func click(_ panel: NSWindow) {
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 100, y: 50), modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        panel.sendEvent(event)
    }

    @Test func viewsThatRefuseTheFirstClickStillGetIt() {
        let recorder = ClickRecorder()
        let panel = panel(with: recorder)
        defer { panel.orderOut(nil) }
        #expect(!panel.isKeyWindow)
        click(panel)
        #expect(recorder.clicks == 1)
        // 正文、标题框这类要打字的视图：窗口顺便成为 key，接下来的按键交给它。
        #expect(panel.isKeyWindow)
    }

    @Test func viewsThatTakeTheFirstClickGetItWithoutTakingTheKeyboard() {
        let recorder = ClickRecorder()
        recorder.firstMouse = true
        let panel = panel(with: recorder)
        defer { panel.orderOut(nil) }
        panel.becomesKeyOnlyIfNeeded = true
        click(panel)
        #expect(recorder.clicks == 1)
        #expect(!panel.isKeyWindow)
    }

    /// 面板也一样：预览是 key 时点面板上的卡片，第一下就要交给卡片。
    @Test func thePanelPassesItsFirstClickOnToo() {
        let recorder = ClickRecorder()
        let panel = ClipPanel()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        recorder.frame = content.bounds
        content.addSubview(recorder)
        panel.contentView = content
        panel.setFrame(NSRect(x: 0, y: 0, width: 200, height: 100), display: false)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        click(panel)
        #expect(recorder.clicks == 1)
    }

    /// 点了以后没有控件要键盘（第一响应者还是窗口自己），预览把键盘还给面板；点进要打字的视图时留着。
    @Test func clicksThatNeedNoKeyboardGiveItBack() {
        final class Typing: ClickRecorder {
            override var acceptsFirstResponder: Bool { true }
            override func mouseDown(with event: NSEvent) {
                super.mouseDown(with: event)
                window?.makeFirstResponder(self)
            }
        }
        for (recorder, keepsKeyboard) in [(ClickRecorder(), false), (Typing(), true)] {
            let preview = panel(with: recorder)
            defer { preview.orderOut(nil) }
            var givenBack = 0
            preview.onClickWithoutKeyboard = { givenBack += 1 }
            click(preview)
            #expect(recorder.clicks == 1)
            #expect(givenBack == (keepsKeyboard ? 0 : 1))
        }
    }

    /// 点按钮、点图片不需要键盘：这些视图接受第一下点击，预览窗口不抢走面板的键盘焦点。
    @Test func buttonsAndImagesTakeTheFirstClick() {
        #expect(FirstClickHostingView(rootView: Text("预览")).acceptsFirstMouse(for: nil))
        #expect(FirstClickImageView().acceptsFirstMouse(for: nil))
        #expect(ZoomingScrollView().acceptsFirstMouse(for: nil))
        #expect(CenteringClipView().acceptsFirstMouse(for: nil))
    }
}
