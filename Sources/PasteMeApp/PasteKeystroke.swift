import AppKit
import ApplicationServices
import Carbon.HIToolbox
import PasteMeCore
import Security

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

    /// 启动时调用，在 `requestTrust` 之前：需要时删掉系统设置里这个应用失效的辅助功能条目（ADR 0011）。
    ///
    /// 系统按签名记授权。签名变了（从临时签名换成 PasteMe Release 证书、证书换了）以后，列表里旧的 PasteMe
    /// 还开着开关却不起作用，`requestTrust` 也不会再把新的加进去，用户得自己删掉旧的、点加号找应用。
    /// 先删掉它，接着的 `requestTrust` 就会把新的 PasteMe 加进列表，用户只要打开开关。什么时候删由 `StaleGrant` 决定。
    static func forgetStaleGrantIfNeeded(settings: Settings) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let situation = StaleGrant.Situation(
            isTrusted: isTrusted,
            requirement: designatedRequirement(),
            appPath: Bundle.main.bundleURL.path,
            registeredPath: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path,
            handledRequirement: settings.accessibilityRequirement
        )
        switch StaleGrant.action(for: situation) {
        case .nothing:
            break
        case .remember(let requirement):
            settings.accessibilityRequirement = requirement
        case .reset(let requirement):
            if resetGrant(bundleID: bundleID) { settings.accessibilityRequirement = requirement }
        }
    }

    /// 正在运行的应用的 designated requirement，系统按它记授权。
    private static func designatedRequirement() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess
        else { return nil }
        return text as String?
    }

    /// `tccutil reset Accessibility <bundle id>`，成功时返回 true。找不到 bundle id 时（-10814）退出码不是 0，写进日志。
    private static func resetGrant(bundleID: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            NSLog("PasteMe: 运行 tccutil 失败：\(error)")
            return false
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            NSLog("PasteMe: 没有清掉失效的辅助功能条目（tccutil 退出码 %d）：%@", process.terminationStatus, text)
            return false
        }
        return true
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
