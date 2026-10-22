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
}
