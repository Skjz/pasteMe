import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 向当前前台应用发送 ⌘V。
///
/// 发送合成按键需要“辅助功能”权限。没有权限时内容仍会写入剪贴板，用户可以手动按 ⌘V。
@MainActor
enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 弹出系统的辅助功能授权提示（已授权时不弹）。
    @discardableResult
    static func requestTrust() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func sendPasteKeystroke() {
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
