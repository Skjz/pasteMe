import Foundation

/// 按键组合：虚拟键码（Carbon 的 `kVK_…`，按键的物理位置）加修饰键。全局快捷键用它（#50）。
public struct KeyCombo: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    public var keyCode: Int
    public var modifiers: Modifiers

    public init(keyCode: Int, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// 有全局快捷键的功能（#50）。
public enum GlobalAction: String, CaseIterable, Sendable {
    case panel
    case pause
    case pasteStack

    public var title: String {
        switch self {
        case .panel: "呼出或收起面板"
        case .pause: "暂停或恢复记录"
        case .pasteStack: "开启或退出 Paste Stack"
        }
    }

    /// 没改过时的快捷键。键码是 Carbon 的 `kVK_ANSI_V`（9）和 `kVK_ANSI_C`（8），这里不引入 Carbon。
    public var defaultCombo: KeyCombo {
        switch self {
        case .panel: KeyCombo(keyCode: 9, modifiers: [.command, .shift])
        // 不用 ⌥⇧⌘V：很多应用用它“粘贴并匹配样式”。
        case .pause: KeyCombo(keyCode: 9, modifiers: [.command, .shift, .control])
        case .pasteStack: KeyCombo(keyCode: 8, modifiers: [.command, .shift, .control])
        }
    }
}

/// 录下的新组合能不能用（#50）。
public enum ShortcutRules {
    /// 新组合的问题，可以用时为 nil。有问题时不保存。
    ///
    /// - Parameters:
    ///   - current: 各个功能现在的快捷键，清除了的不在里面。
    ///   - isReservedBySystem: 是不是系统设置「键盘快捷键」里打开着的组合。
    public static func problem(
        with combo: KeyCombo,
        for action: GlobalAction,
        current: [GlobalAction: KeyCombo],
        isReservedBySystem: (KeyCombo) -> Bool
    ) -> String? {
        // 只带 ⇧ 或者不带修饰键的组合，在别的应用里打字时也会被拦下。
        guard !combo.modifiers.isDisjoint(with: [.command, .option, .control]) else {
            return "要带上 ⌘、⌃ 或 ⌥ 中的至少一个"
        }
        if let other = GlobalAction.allCases.first(where: { $0 != action && current[$0] == combo }) {
            return "和「\(other.title)」的快捷键相同"
        }
        if isReservedBySystem(combo) {
            return "系统已经用了这个组合"
        }
        return nil
    }
}
