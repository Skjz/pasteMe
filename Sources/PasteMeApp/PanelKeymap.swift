import Carbon.HIToolbox
import Foundation
import PasteMeCore

/// 面板上接收键盘操作的区域。
enum PanelFocus: Equatable {
    case search
    case cards
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
}

/// 判断按键时需要知道的面板状态。
struct PanelContext: Equatable {
    var focus: PanelFocus
    var queryIsEmpty: Bool
    var canUndoDelete: Bool
}

enum PanelCommand: Equatable {
    case close
    case clearSearch
    case moveSelection(by: Int)
    case focus(PanelFocus)
    case paste(PasteMode)
    case pasteAt(index: Int, PasteMode)
    case deleteSelected
    case undoDelete
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
/// 焦点在卡片列表时，它们操作卡片。↓ 从搜索框进入卡片列表，↑ 回到搜索框；在卡片上打字也会回到搜索框。
enum PanelKeymap {
    static func action(for key: PanelKey, in context: PanelContext) -> PanelKeyAction {
        let onCards = context.focus == .cards
        let mode: PasteMode = key.shift ? .plainText : .original

        switch key.keyCode {
        case kVK_Escape:
            return .run(context.queryIsEmpty ? .close : .clearSearch)
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
            return key.command ? .run(.deleteSelected) : .focusSearchThenPassThrough
        case kVK_ANSI_Z where onCards && key.command && !key.shift:
            return context.canUndoDelete ? .run(.undoDelete) : .passThrough
        default:
            break
        }

        if key.command, let index = digitKeyCodes.firstIndex(of: key.keyCode) {
            return .run(.pasteAt(index: index, mode))
        }
        if onCards, !key.command, !key.control, producesText(key.characters) {
            return .focusSearchThenPassThrough
        }
        return .passThrough
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
