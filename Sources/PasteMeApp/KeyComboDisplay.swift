import AppKit
import Carbon.HIToolbox
import PasteMeCore

/// `KeyCombo` 在 AppKit 和 Carbon 里的样子：注册用的修饰键、菜单项上的按键、提示文字里的符号（#50）。
extension KeyCombo {
    /// Carbon 修饰键组合，例如 `cmdKey | shiftKey`。
    var carbonModifiers: Int {
        var value = 0
        if modifiers.contains(.control) { value |= controlKey }
        if modifiers.contains(.option) { value |= optionKey }
        if modifiers.contains(.shift) { value |= shiftKey }
        if modifiers.contains(.command) { value |= cmdKey }
        return value
    }

    var modifierMask: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return flags
    }

    /// 录制时按下的键。只看 ⌃⌥⇧⌘，大写锁定和 fn 不算。
    init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        var modifiers: Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        self.init(keyCode: Int(keyCode), modifiers: modifiers)
    }

    /// 写在提示文字里的样子，例如 "⇧⌘V"。按键的字符取当前的键盘布局。
    @MainActor
    var symbol: String {
        symbol(character: KeyNames.layoutCharacter(for:))
    }

    /// 修饰键按系统菜单的顺序 ⌃⌥⇧⌘ 排在前面。`character` 给出按键在键盘布局里的字符，测试替换它。
    func symbol(character: (Int) -> String?) -> String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + KeyNames.name(of: keyCode, character: character)
    }

    /// 菜单项右侧显示的按键（`NSMenuItem.keyEquivalent`）：字符键用小写字符，功能键用 AppKit 的功能键字符。
    @MainActor
    var keyEquivalent: String {
        if let special = KeyNames.menuEquivalents[keyCode] { return String(Character(UnicodeScalar(special)!)) }
        return KeyNames.layoutCharacter(for: keyCode)?.lowercased() ?? ""
    }
}

enum KeyNames {
    /// 没有字符、或者字符看不见的键，按系统菜单的写法。
    static let specialNames: [Int: String] = {
        var names: [Int: String] = [
            kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "空格",
            kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        ]
        for (index, code) in functionKeys.enumerated() {
            names[code] = "F\(index + 1)"
        }
        return names
    }()

    /// 这些键在菜单项上的字符（`NSF1FunctionKey` 等）。
    static let menuEquivalents: [Int: Int] = {
        var keys: [Int: Int] = [
            kVK_Return: 0x0D, kVK_ANSI_KeypadEnter: 0x03, kVK_Tab: 0x09, kVK_Space: 0x20,
            kVK_Delete: 0x08, kVK_ForwardDelete: NSDeleteFunctionKey, kVK_Escape: 0x1B,
            kVK_LeftArrow: NSLeftArrowFunctionKey, kVK_RightArrow: NSRightArrowFunctionKey,
            kVK_UpArrow: NSUpArrowFunctionKey, kVK_DownArrow: NSDownArrowFunctionKey,
            kVK_Home: NSHomeFunctionKey, kVK_End: NSEndFunctionKey,
            kVK_PageUp: NSPageUpFunctionKey, kVK_PageDown: NSPageDownFunctionKey,
        ]
        for (index, code) in functionKeys.enumerated() {
            keys[code] = NSF1FunctionKey + index
        }
        return keys
    }()

    private static let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    /// 按键的名字：特殊键查表，其余用键盘布局里的字符（大写）。都取不到时写键码。
    static func name(of keyCode: Int, character: (Int) -> String?) -> String {
        if let name = specialNames[keyCode] { return name }
        if let character = character(keyCode) { return character.uppercased() }
        return "键 \(keyCode)"
    }

    /// 按键在当前键盘布局里不按修饰键时的字符。用拼音这类输入法时，取它下面的键盘布局（多半是 ABC）。
    /// 键码是按键的物理位置，换了键盘布局（例如法语 AZERTY）同一个键显示的字符也跟着变。
    @MainActor
    static func layoutCharacter(for keyCode: Int) -> String? {
        let sources = [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()]
        for source in sources {
            guard let source = source?.takeRetainedValue(),
                  let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { continue }
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
            var deadKeyState: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = data.withUnsafeBytes { buffer in
                UCKeyTranslate(
                    buffer.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self),
                    UInt16(keyCode),
                    UInt16(kUCKeyActionDisplay),
                    0,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    characters.count,
                    &length,
                    &characters
                )
            }
            guard status == noErr, length > 0 else { continue }
            let text = String(utf16CodeUnits: characters, count: length)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).isEmpty { return text }
        }
        return nil
    }
}

/// 系统设置「键盘快捷键」里打开着的组合（截图、调度中心、切换输入法……）。
enum SystemShortcuts {
    /// 一条系统快捷键：键码和 Carbon 修饰键（可能带着 fn 这类别的位，比较时只看 ⌃⌥⇧⌘）。
    struct Entry: Equatable {
        var keyCode: Int
        var carbonModifiers: Int
        var enabled: Bool
    }

    static func contains(_ combo: KeyCombo, in entries: [Entry]) -> Bool {
        let mask = controlKey | optionKey | shiftKey | cmdKey
        return entries.contains { $0.enabled && $0.keyCode == combo.keyCode && $0.carbonModifiers & mask == combo.carbonModifiers }
    }

    /// 当前打开着的系统快捷键。`CopySymbolicHotKeys` 还在 HIToolbox 里，但新的 SDK 不再带它的头文件，
    /// 所以按名字找到它再调用；找不到时当作没有系统快捷键。
    static func current() -> [Entry] {
        typealias CopySymbolicHotKeys = @convention(c) (UnsafeMutablePointer<Unmanaged<CFArray>?>) -> OSStatus
        let path = "/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/HIToolbox"
        guard let handle = dlopen(path, RTLD_NOW), let symbol = dlsym(handle, "CopySymbolicHotKeys") else { return [] }
        let copy = unsafeBitCast(symbol, to: CopySymbolicHotKeys.self)
        var array: Unmanaged<CFArray>?
        guard copy(&array) == noErr, let list = array?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let code = entry["kHISymbolicHotKeyCode"] as? Int,
                  let modifiers = entry["kHISymbolicHotKeyModifiers"] as? Int
            else { return nil }
            return Entry(keyCode: code, carbonModifiers: modifiers, enabled: entry["kHISymbolicHotKeyEnabled"] as? Bool ?? false)
        }
    }
}
