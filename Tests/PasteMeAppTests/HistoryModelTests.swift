import Foundation
import Testing
@testable import PasteMeApp
import PasteMeCore

@MainActor
@Suite struct HistoryModelTests {
    let store: ClipStore
    let model: HistoryModel
    /// 历史里从新到旧的 id：c、b、a。
    let c, b, a: Int64

    init() throws {
        store = try ClipStore(path: ":memory:")
        a = try store.insert(ClipContent(kind: .text, text: "a"), source: nil, at: Date(timeIntervalSince1970: 1))
        b = try store.insert(ClipContent(kind: .text, text: "b"), source: nil, at: Date(timeIntervalSince1970: 2))
        c = try store.insert(ClipContent(kind: .text, text: "c"), source: nil, at: Date(timeIntervalSince1970: 3))
        model = HistoryModel(store: store)
        model.didShow()
    }

    @Test func showingPanelSelectsNewestItem() {
        #expect(model.items.map(\.id) == [c, b, a])
        #expect(model.selectedID == c)
    }

    @Test func moveSelectionStepsThroughItems() {
        model.moveSelection(by: 1)
        #expect(model.selectedID == b)
        model.moveSelection(by: 1)
        #expect(model.selectedID == a)
        model.moveSelection(by: -1)
        #expect(model.selectedID == b)
    }

    @Test func moveSelectionStopsAtEnds() {
        model.moveSelection(by: -1)
        #expect(model.selectedID == c)
        model.moveSelection(by: 10)
        #expect(model.selectedID == a)
        model.moveSelection(by: 1)
        #expect(model.selectedID == a)
    }

    @Test func moveSelectionOnEmptyHistoryDoesNothing() throws {
        let empty = HistoryModel(store: try ClipStore(path: ":memory:"))
        empty.didShow()
        empty.moveSelection(by: 1)
        #expect(empty.selectedID == nil)
    }

    @Test func deletingSelectedItemSelectsTheOneThatTakesItsPlace() throws {
        model.moveSelection(by: 1)
        model.delete()

        #expect(model.items.map(\.id) == [c, a])
        #expect(model.selectedID == a)
        #expect(try store.count() == 2)
    }

    @Test func deletingLastItemSelectsNewLast() {
        model.moveSelection(by: 2)
        model.delete()

        #expect(model.items.map(\.id) == [c, b])
        #expect(model.selectedID == b)
    }

    @Test func deletingOnlyItemClearsSelection() {
        model.delete(model.items[0])
        model.delete(model.items[0])
        model.delete()

        #expect(model.items.isEmpty)
        #expect(model.selectedID == nil)
    }

    @Test func searchKeepsSelectionWhenStillListedOtherwiseSelectsFirst() {
        model.moveSelection(by: 1)
        model.query = "b"
        model.reload()
        #expect(model.selectedID == b)

        model.query = "a"
        model.reload()
        #expect(model.selectedID == a)
    }

    @Test func undoDeleteRestoresItemInPlaceAndSelectsIt() {
        model.moveSelection(by: 1)
        model.delete()
        #expect(model.canUndoDelete)

        model.undoDelete()

        #expect(model.items.map(\.id) == [c, b, a])
        #expect(model.selectedID == b)
        #expect(!model.canUndoDelete)
    }

    @Test func undoDeleteRestoresInReverseOrder() {
        model.delete()
        model.delete()
        #expect(model.items.map(\.id) == [a])

        model.undoDelete()
        #expect(model.items.map(\.id) == [b, a])
        model.undoDelete()
        #expect(model.items.map(\.id) == [c, b, a])
        #expect(model.selectedID == c)
    }

    @Test func reopeningPanelForgetsDeletionsAndResetsFocus() {
        model.focus = .cards
        model.delete()

        model.didShow()

        #expect(!model.canUndoDelete)
        #expect(model.focus == .search)
    }
}
