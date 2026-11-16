import Foundation
import Testing
@testable import PasteMeApp
import PasteMeCore

/// 在面板里按 ⌘C 拷贝选中的卡片（#35）：面板不收起，卡片不动，收起后才移到历史最前。
@MainActor
@Suite final class CopyFromPanelTests {
    let store: ClipStore
    let model: HistoryModel
    /// 历史里从新到旧：c、b、a。
    let c, b, a: Int64
    var copied: [Int64] = []
    var notices: [String] = []

    init() throws {
        store = try ClipStore(path: ":memory:")
        a = try store.insert(ClipContent(kind: .text, text: "a"), source: nil, at: Date(timeIntervalSince1970: 1))
        b = try store.insert(ClipContent(kind: .text, text: "b"), source: nil, at: Date(timeIntervalSince1970: 2))
        c = try store.insert(ClipContent(kind: .text, text: "c"), source: nil, at: Date(timeIntervalSince1970: 3))
        model = HistoryModel(store: store) { Date(timeIntervalSince1970: 100) }
        model.onCopy = { [unowned self] in copied.append($0.id) }
        model.onNotice = { [unowned self] message, _ in notices.append(message) }
        model.didShow()
    }

    @Test func copyingKeepsTheCardsWhereTheyAre() {
        model.moveSelection(by: 2)
        model.copy()
        #expect(copied == [a])
        #expect(notices == ["已拷贝"])
        #expect(model.items.map(\.id) == [c, b, a])
        #expect(model.selectedID == a)
    }

    @Test func theCopiedEntryMovesToTheTopWhenThePanelCloses() throws {
        model.moveSelection(by: 1)
        model.copy()
        model.moveSelection(by: 1)
        model.copy()
        model.panelWillHide()
        model.didShow()
        // 只有最后拷贝的那条在剪贴板里，也只有它移到最前。
        #expect(model.items.map(\.id) == [a, c, b])
    }

    @Test func closingWithoutCopyingChangesNothing() {
        model.panelWillHide()
        model.didShow()
        #expect(model.items.map(\.id) == [c, b, a])
    }

    @Test func pinboardOrderStaysTheSame() throws {
        let pinboard = try store.createPinboard(name: "工作", color: .blue)
        try store.pin(a, to: pinboard.id)
        try store.pin(b, to: pinboard.id)
        model.reloadPinboards()
        model.showTab(pinboard.id)
        let order = model.items.map(\.id)
        model.moveSelection(by: 1)
        model.copy()
        model.panelWillHide()
        model.didShow()
        model.showTab(pinboard.id)
        #expect(model.items.map(\.id) == order)
    }

    @Test func copyingAddsToPasteStackOnlyWhileStackIsOn() throws {
        let stack = PasteStack()
        let stackedModel = HistoryModel(store: store, pasteStack: stack) { Date(timeIntervalSince1970: 100) }
        stackedModel.onCopy = { [unowned self] in copied.append($0.id) }
        stackedModel.onNotice = { [unowned self] message, _ in notices.append(message) }
        stackedModel.didShow()

        // 没开启时只拷贝，不开启栈。
        stackedModel.copy()
        #expect(!stack.isActive && stack.entries.isEmpty)
        #expect(notices == ["已拷贝"])

        // 开启后依次按 ⌘C，包括同一张拷贝两次，也在 Pinboard 里拷贝。
        let pinboard = try store.createPinboard(name: "常用", color: .green)
        try store.pin(a, to: pinboard.id)
        stackedModel.reloadPinboards()

        stack.start()
        stackedModel.copy()
        stackedModel.moveSelection(by: 1)
        stackedModel.copy()
        stackedModel.copy()
        stackedModel.showTab(pinboard.id)
        stackedModel.copy()

        #expect(stack.entries == [c, b, b, a])
        #expect(notices.suffix(4) == [
            "已加入 Paste Stack（第 1 条）",
            "已加入 Paste Stack（第 2 条）",
            "已加入 Paste Stack（第 3 条）",
            "已加入 Paste Stack（第 4 条）",
        ])
    }

    @Test func contextMenuStartsPasteStackOrRefusesWhenBlocked() {
        let stack = PasteStack()
        let stackedModel = HistoryModel(store: store, pasteStack: stack) { Date(timeIntervalSince1970: 100) }
        stackedModel.onCopy = { [unowned self] in copied.append($0.id) }
        stackedModel.onNotice = { [unowned self] message, _ in notices.append(message) }
        stackedModel.didShow()

        // 模拟暂停记录时开启被拒。
        var allowStart = false
        stackedModel.onStartPasteStack = { item in
            guard allowStart else { return false }
            stack.add(item.id)
            return true
        }
        stackedModel.addToPasteStack()
        #expect(!stack.isActive && stack.entries.isEmpty && copied.isEmpty)

        // 允许开启后，右键第一张开启并作为第一条，再对下一张操作时追加到最后。
        allowStart = true
        stackedModel.addToPasteStack()
        #expect(stack.isActive && stack.entries == [c] && copied == [c])

        stackedModel.moveSelection(by: 1)
        stackedModel.addToPasteStack()
        #expect(stack.entries == [c, b] && copied == [c, b])
        #expect(notices.last == "已加入 Paste Stack（第 2 条）")
    }
}
