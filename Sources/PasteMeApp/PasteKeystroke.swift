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

    /// 删掉系统设置里这个应用失效的辅助功能条目（ADR 0011）。
    ///
    /// 系统按签名记授权。签名变了（从临时签名换成 PasteMe Release 证书、证书换了）以后，列表里旧的 PasteMe
    /// 还开着开关却不起作用，`requestTrust` 也不会再把新的加进去，用户得自己删掉旧的、点加号找应用。
    /// 先删掉它，接着的 `requestTrust` 就会把新的 PasteMe 加进列表，用户只要打开开关。
    /// 只在启动时、没有授权时调用：有效的授权不会被删，用户关掉的开关会变成重新询问一次。
    static func forgetStaleGrant(bundleID: String? = Bundle.main.bundleIdentifier) {
        guard let bundleID else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("PasteMe: 清除失效的辅助功能条目失败：\(error)")
        }
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
    /// 写在合成按键的 `eventSourceUserData` 里，Paste Stack 的事件监听据此认出这是 PasteMe 自己发的 ⌘V。"PMEV"
    static let marker: Int64 = 0x504D_4556

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
        for event in [down, up] {
            event?.flags = .maskCommand
            event?.setIntegerValueField(.eventSourceUserData, value: marker)
        }
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
