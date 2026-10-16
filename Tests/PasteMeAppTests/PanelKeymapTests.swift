import Carbon.HIToolbox
import Testing
@testable import PasteMeApp

@Suite struct PanelKeymapTests {
    static let searching = PanelContext(focus: .search, queryIsEmpty: false, canUndoDelete: true)
    static let searchEmpty = PanelContext(focus: .search, queryIsEmpty: true, canUndoDelete: true)
    static let onCards = PanelContext(focus: .cards, queryIsEmpty: false, canUndoDelete: true)

    static let commandDelete = PanelKey(keyCode: kVK_Delete, command: true, characters: "\u{7f}")
    static let commandZ = PanelKey(keyCode: kVK_ANSI_Z, command: true, characters: "z")
    static let left = PanelKey(keyCode: kVK_LeftArrow, characters: "\u{F702}")
    static let right = PanelKey(keyCode: kVK_RightArrow, characters: "\u{F703}")

    private func action(_ key: PanelKey, _ context: PanelContext) -> PanelKeyAction {
        PanelKeymap.action(for: key, in: context)
    }

    // MARK: 焦点在搜索框

    @Test func commandDeleteInSearchFieldEditsTextInsteadOfDeletingClip() {
        #expect(action(Self.commandDelete, Self.searching) == .passThrough)
        #expect(action(Self.commandDelete, Self.searchEmpty) == .passThrough)
    }

    @Test func commandZInSearchFieldUndoesTyping() {
        #expect(action(Self.commandZ, Self.searching) == .passThrough)
    }

    @Test func arrowsMoveCursorWhenSearchHasText() {
        #expect(action(Self.left, Self.searching) == .passThrough)
        #expect(action(Self.right, Self.searching) == .passThrough)
    }

    @Test func arrowsSelectCardsWhenSearchIsEmpty() {
        #expect(action(Self.left, Self.searchEmpty) == .run(.moveSelection(by: -1)))
        #expect(action(Self.right, Self.searchEmpty) == .run(.moveSelection(by: 1)))
    }

    @Test func downArrowMovesFocusToCards() {
        #expect(action(PanelKey(keyCode: kVK_DownArrow), Self.searching) == .run(.focus(.cards)))
    }

    @Test func typingInSearchFieldPassesThrough() {
        #expect(action(PanelKey(keyCode: kVK_ANSI_A, characters: "a"), Self.searching) == .passThrough)
    }

    // MARK: 焦点在卡片列表

    @Test func commandDeleteOnCardsDeletesSelectedClip() {
        #expect(action(Self.commandDelete, Self.onCards) == .run(.deleteSelected))
    }

    @Test func commandZOnCardsUndoesDelete() {
        #expect(action(Self.commandZ, Self.onCards) == .run(.undoDelete))
    }

    @Test func commandZOnCardsWithNothingToUndoPassesThrough() {
        var context = Self.onCards
        context.canUndoDelete = false
        #expect(action(Self.commandZ, context) == .passThrough)
    }

    @Test func commandShiftZIsNotUndo() {
        var key = Self.commandZ
        key.shift = true
        #expect(action(key, Self.onCards) == .passThrough)
    }

    @Test func arrowsOnCardsMoveSelectionEvenWithSearchText() {
        #expect(action(Self.left, Self.onCards) == .run(.moveSelection(by: -1)))
        #expect(action(Self.right, Self.onCards) == .run(.moveSelection(by: 1)))
    }

    @Test func upArrowReturnsFocusToSearch() {
        #expect(action(PanelKey(keyCode: kVK_UpArrow), Self.onCards) == .run(.focus(.search)))
    }

    @Test func typingOnCardsGoesToSearchField() {
        #expect(action(PanelKey(keyCode: kVK_ANSI_A, characters: "a"), Self.onCards) == .focusSearchThenPassThrough)
        #expect(action(PanelKey(keyCode: kVK_ANSI_A, shift: true, characters: "A"), Self.onCards) == .focusSearchThenPassThrough)
        #expect(action(PanelKey(keyCode: kVK_Delete, characters: "\u{7f}"), Self.onCards) == .focusSearchThenPassThrough)
    }

    @Test func nonTextKeysOnCardsStayOnCards() {
        #expect(action(PanelKey(keyCode: kVK_Tab, characters: "\t"), Self.onCards) == .passThrough)
        #expect(action(PanelKey(keyCode: kVK_F5, characters: "\u{F708}"), Self.onCards) == .passThrough)
        #expect(action(PanelKey(keyCode: kVK_ANSI_A, command: true, characters: "a"), Self.onCards) == .passThrough)
    }

    // MARK: 两种焦点下相同

    @Test func escapeClearsSearchFirstThenCloses() {
        let escape = PanelKey(keyCode: kVK_Escape, characters: "\u{1b}")
        #expect(action(escape, Self.searching) == .run(.clearSearch))
        #expect(action(escape, Self.onCards) == .run(.clearSearch))
        #expect(action(escape, Self.searchEmpty) == .run(.close))
    }

    @Test func returnPastesInBothFocuses() {
        let enter = PanelKey(keyCode: kVK_Return, characters: "\r")
        #expect(action(enter, Self.searching) == .run(.paste(.original)))
        #expect(action(enter, Self.onCards) == .run(.paste(.original)))
        var shiftEnter = enter
        shiftEnter.shift = true
        #expect(action(shiftEnter, Self.onCards) == .run(.paste(.plainText)))
    }

    @Test func commandDigitPastesNthItem() {
        let commandThree = PanelKey(keyCode: kVK_ANSI_3, command: true, characters: "3")
        #expect(action(commandThree, Self.searching) == .run(.pasteAt(index: 2, .original)))
        var shifted = commandThree
        shifted.shift = true
        shifted.characters = "#"
        #expect(action(shifted, Self.onCards) == .run(.pasteAt(index: 2, .plainText)))
    }
}
