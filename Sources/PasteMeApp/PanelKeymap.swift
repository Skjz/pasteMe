import Carbon.HIToolbox
import Foundation
import PasteMeCore

/// 面板上接收键盘操作的区域。
enum PanelFocus: Equatable {
    case search
    case cards
    /// 在选中卡片的标题栏里编辑标题（#33）。
    case title
}

/// 一次按键，从 `NSEvent` 中取出决定面板行为所需的部分。
struct PanelKey: Equatable {
    var keyCode: Int
    var command = false
    var shift = false
    var option = false
    var control = false
    /// 按键产生的文字（`NSEvent.characters`）。
    var characters = ""

    var keyCombo: KeyCombo {
        var modifiers: KeyCombo.Modifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return KeyCombo(keyCode: keyCode, modifiers: modifiers)
    }
}

/// 判断按键时需要知道的面板状态。
struct PanelContext: Equatable {
    var focus: PanelFocus
    var queryIsEmpty: Bool
    var canUndoDelete: Bool
    /// 面板上选了类型、来源应用或时间筛选。
    var filtersActive = false
    /// 搜索框下面显示着 `@` 的候选列表。
    var suggestionsShown = false
    /// 输入法正在组字：搜索框里有还没确认的文字（拼音等）。
    var composing = false
    /// 预览窗口开着。
    var previewShown = false
    /// 预览的是几个文件的条目，可以用 ⌥← ⌥→ 换着看。
    var previewHasSeveralFiles = false
}

enum PanelCommand: Equatable {
    case close
    case clearSearch
    case moveSelection(by: Int)
    case focus(PanelFocus)
    case paste(PasteMode)
    /// ⌘1…⌘9：`index` 从 0 开始，从第一张完整显示的卡片数起（#39），见 `HistoryModel.paste(at:as:)`。
    case pasteAt(index: Int, PasteMode)
    case deleteSelected
    case undoDelete
    case moveSuggestion(by: Int)
    case acceptSuggestion
    case dismissSuggestions
    case togglePreview
    case closePreview
    case editSelected
    case newText
    case switchTab(by: Int)
    case pinSelected
    case showInHistory
    case showConversions
    /// ⌘R：在选中卡片的标题栏里起标题、改标题（#33）。
    case renameSelected
    case commitTitle
    case cancelTitle
    /// ⌘C：把选中的条目拷贝到剪贴板，不粘贴（#35）。
    case copySelected
    /// ⌘O：打开选中的链接、文件或文件夹（#51）。
    case openSelected
    /// ⌥← ⌥→：预览几个文件的条目时换成上一个、下一个文件。
    case previewFile(by: Int)
}

/// 按键交给谁处理。
enum PanelKeyAction: Equatable {
    /// 面板执行命令，按键不再往下传。
    case run(PanelCommand)
    /// 交给当前的第一响应者（焦点在搜索框时就是搜索框）。
    case passThrough
    /// 先把焦点移回搜索框，再把按键交给它。焦点在卡片上时打字，文字进入搜索框。
    case focusSearchThenPassThrough
}

/// 把按键和面板状态转成面板命令。
///
/// 焦点规则（工单 #1）：焦点在搜索框时，编辑文字的按键（⌘⌫、⌘Z，以及有搜索词时的 ← →）交给搜索框；
/// 焦点在卡片列表时，它们操作卡片。↓ 从搜索框进入卡片列表，↑ 回到搜索框；在卡片上打字也会进入搜索框。
///
/// 搜索框下面显示着 `@` 的候选列表时，↑ ↓ 在列表里移动，↩ 和 Tab 选中，esc 关掉列表。
/// 输入法组字时 ↩、方向键、esc 是用来选字和取消的，所有按键都交给输入法。
///
/// 在卡片标题栏里编辑标题时（#33），↩ 保存，esc 取消，其他按键都交给输入框。焦点在卡片上时 ⌘R 开始编辑标题，
/// ⌘C 把选中的条目拷贝到剪贴板（#35）；焦点在搜索框时这两个键交给搜索框。
///
/// 焦点在卡片上时空格打开预览，预览开着时空格和 esc 关掉它（#10）。⌘T 在选中的卡片下面弹出「转换」菜单（#27），
/// ⌘O 打开选中的链接、文件或文件夹（#51），这两个在搜索框里也起作用。⌘← ⌘→ 在「历史」和各个 Pinboard
/// 之间切换，规则和 ← → 一样：搜索框里有文字时交给搜索框移动插入点（#9）。
enum PanelKeymap {
    /// 可录制面板命令的默认组合（#69）。
    static let defaultShortcuts: [PanelShortcutAction: KeyCombo] = Dictionary(
        uniqueKeysWithValues: PanelShortcutAction.allCases.map { ($0, $0.defaultCombo) }
    )

    /// 按着这些修饰键时卡片上显示 ⌘1…⌘9（#39）：⌘，或者 ⇧⌘（以纯文本粘贴）。还按着 ⌥ 或 ⌃ 时不显示。
    static func showsShortcutHints(command: Bool, option: Bool, control: Bool) -> Bool {
        command && !option && !control
    }

    static func action(
        for key: PanelKey,
        in context: PanelContext,
        shortcuts: [PanelShortcutAction: KeyCombo] = defaultShortcuts
    ) -> PanelKeyAction {
        guard !context.composing else { return .passThrough }
        let onCards = context.focus == .cards
        let mode: PasteMode = key.shift ? .plainText : .original

        if context.focus == .title {
            switch key.keyCode {
            case kVK_Return, kVK_ANSI_KeypadEnter: return .run(.commitTitle)
            case kVK_Escape: return .run(.cancelTitle)
            default: return .passThrough
            }
        }

        if context.suggestionsShown, !key.command, !key.control, !key.option {
            switch key.keyCode {
            case kVK_DownArrow: return .run(.moveSuggestion(by: 1))
            case kVK_UpArrow: return .run(.moveSuggestion(by: -1))
            case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab: return .run(.acceptSuggestion)
            case kVK_Escape: return .run(.dismissSuggestions)
            default: break
            }
        }

        if context.previewShown {
            if key.keyCode == kVK_Escape { return .run(.closePreview) }
            if key.keyCode == kVK_Space, onCards, !key.command { return .run(.closePreview) }
            // 搜索框里有文字时 ⌥← ⌥→ 按词移动插入点，交给搜索框。
            if context.previewHasSeveralFiles, key.option, !key.command, !key.control, onCards || context.queryIsEmpty,
               key.keyCode == kVK_LeftArrow || key.keyCode == kVK_RightArrow {
                return .run(.previewFile(by: key.keyCode == kVK_LeftArrow ? -1 : 1))
            }
        }

        // 先查用户可录制的面板内快捷键（#69），再走下面写死的规则。
        let combo = key.keyCombo
        if let shortcutAction = PanelShortcutAction.allCases.first(where: { shortcuts[$0] == combo }) {
            // 搜索框有文字时，如果这个组合在文本框里有编辑含义（例如 ⌘← 移到行首），仍交给搜索框。
            if !onCards, !context.queryIsEmpty, editsSearchText(key) {
                return .passThrough
            }
            return .run(command(for: shortcutAction))
        }

        if key.command, !key.control, !key.option {
            switch key.keyCode {
            case kVK_ANSI_P where !key.shift: return .run(.pinSelected)
            case kVK_ANSI_N where !key.shift: return .run(.newText)
            case kVK_ANSI_E where !key.shift: return .run(.editSelected)
            case kVK_ANSI_J where !key.shift: return .run(.showInHistory)
            case kVK_ANSI_O where !key.shift: return .run(.openSelected)
            case kVK_ANSI_R where !key.shift && onCards: return .run(.renameSelected)
            case kVK_ANSI_C where !key.shift && onCards: return .run(.copySelected)
            default: break
            }
        }

        switch key.keyCode {
        case kVK_Space where onCards && !key.command && !key.control && !key.option:
            return .run(.togglePreview)
        case kVK_Escape:
            // 有搜索词或筛选条件时先清空它们，再按一次才关闭。
            return .run(context.queryIsEmpty && !context.filtersActive ? .close : .clearSearch)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return .run(.paste(mode))
        case kVK_LeftArrow, kVK_RightArrow:
            // 搜索框里有文字时，← → 移动光标；没有文字时没有光标可移，直接选择卡片。
            guard onCards || context.queryIsEmpty else { return .passThrough }
            return .run(.moveSelection(by: key.keyCode == kVK_LeftArrow ? -1 : 1))
        case kVK_DownArrow where !onCards:
            return .run(.focus(.cards))
        case kVK_UpArrow where onCards:
            return .run(.focus(.search))
        case kVK_Delete where onCards:
            if key.command, !key.shift, !key.option, !key.control { return .run(.deleteSelected) }
            if !key.command, !key.option, !key.control { return .focusSearchThenPassThrough }
        case kVK_ANSI_Z where onCards && key.command && !key.shift && !key.option && !key.control:
            return context.canUndoDelete ? .run(.undoDelete) : .passThrough
        default:
            break
        }

        if key.command, !key.option, !key.control, let index = digitKeyCodes.firstIndex(of: key.keyCode) {
            return .run(.pasteAt(index: index, mode))
        }
        if onCards, !key.command, !key.control, producesText(key.characters) {
            return .focusSearchThenPassThrough
        }
        return .passThrough
    }

    private static func command(for action: PanelShortcutAction) -> PanelCommand {
        switch action {
        case .previousTab: .switchTab(by: -1)
        case .nextTab: .switchTab(by: 1)
        case .showConversions: .showConversions
        }
    }

    /// 按键组合在搜索框里是否有移动插入点、选字或删字等编辑含义（#69）。
    /// 像 ⌘[ ⌘]、⇧⌘[ ⇧⌘]、⌃Tab 没有编辑含义，搜索框有文字时也能直接切换标签。
    private static func editsSearchText(_ key: PanelKey) -> Bool {
        let navigationKeys = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End]
        if navigationKeys.contains(key.keyCode) {
            let commandOnly = key.command && !key.option && !key.control
            let optionOnly = key.option && !key.command && !key.control
            return commandOnly || optionOnly
        }
        if key.keyCode == kVK_Delete || key.keyCode == kVK_ForwardDelete {
            return true
        }
        if key.command, !key.option, !key.control, !key.shift {
            return [kVK_ANSI_A, kVK_ANSI_X, kVK_ANSI_V].contains(key.keyCode)
        }
        if key.control, !key.command, !key.option, !key.shift {
            return [kVK_ANSI_A, kVK_ANSI_E, kVK_ANSI_B, kVK_ANSI_F, kVK_ANSI_D, kVK_ANSI_H, kVK_ANSI_K].contains(key.keyCode)
        }
        return false
    }

    /// 面板里写死的快捷键占用的功能名（#69），录制面板内快捷键时不能和它们冲突。没有占用时为 nil。
    static func fixedShortcutTitle(for combo: KeyCombo) -> String? {
        if combo.modifiers == [.command] {
            switch combo.keyCode {
            case kVK_ANSI_P: return "固定到 Pinboard"
            case kVK_ANSI_N: return "新建文本"
            case kVK_ANSI_E: return "编辑"
            case kVK_ANSI_J: return "在历史里查看"
            case kVK_ANSI_O: return "打开"
            case kVK_ANSI_R: return "修改标题"
            case kVK_ANSI_C: return "拷贝"
            case kVK_Delete: return "删除"
            case kVK_ANSI_Z: return "撤销"
            default: break
            }
        }
        if combo.modifiers == [.command] || combo.modifiers == [.command, .shift],
           let index = digitKeyCodes.firstIndex(of: combo.keyCode) {
            return "粘贴第 \(index + 1) 张卡片"
        }
        if combo.modifiers == [.option], combo.keyCode == kVK_LeftArrow || combo.keyCode == kVK_RightArrow {
            return "预览里切换文件"
        }
        return nil
    }

    /// 面板开着时这个组合有没有用处（#50、#69）：全局快捷键设成它时，面板里原来的功能会被全局快捷键拦下。
    static func isUsedByPanel(_ combo: KeyCombo, shortcuts: [PanelShortcutAction: KeyCombo] = defaultShortcuts) -> Bool {
        if fixedShortcutTitle(for: combo) != nil { return true }
        if shortcuts.values.contains(combo) { return true }
        return false
    }

    /// 数字键 1…9 的键码。用键码而不是字符判断，按住 Shift 时 1 会变成 "!"。
    private static let digitKeyCodes = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]

    /// 方向键、功能键等的 `characters` 落在私用区（U+F700…U+F8FF），控制字符也不算文字。
    private static func producesText(_ characters: String) -> Bool {
        guard !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }
}
