import AppKit
import ApplicationServices
import Carbon.HIToolbox
import PasteMeCore

/// 发送合成按键所需的“辅助功能”权限。
@MainActor
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 弹出系统的辅助功能授权提示（已授权时不弹）。
    @discardableResult
    static func requestTrust() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 用 `CGEvent` 合成 ⌘V。
///
/// 按键发给当前前台应用。面板不激活 PasteMe，所以前台应用就是目标应用。
struct CGEventPasteKeystroke: PasteKeystrokeSending {
    var isTrusted: Bool { Accessibility.isTrusted }

    func sendPaste(to target: TargetApp?) {
        // 等面板收起、键盘焦点回到原应用后再发送 ⌘V。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            Self.postCommandV()
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
