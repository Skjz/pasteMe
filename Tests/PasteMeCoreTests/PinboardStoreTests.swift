import Foundation
import Testing
@testable import PasteMeCore

/// Pinboard 的存储：新建和管理、固定和排序、清空历史时保留、删除和撤销时带上固定的位置（#9）。
@Suite struct PinboardStoreTests {
    let store: ClipStore

    init() throws {
        store = try ClipStore(path: ":memory:")
    }

    @discardableResult
    private func insert(_ text: String, at second: Double) throws -> Int64 {
        try store.insert(ClipContent(kind: .text, text: text), source: nil, at: Date(timeIntervalSince1970: second))
    }

    private func previews(in pinboard: Pinboard) throws -> [String?] {
        try store.items(matching: ClipQuery(pinboardID: pinboard.id)).map(\.preview)
    }

    @Test func pinboardsAreListedInTheOrderTheyWereCreated() throws {
        let work = try store.createPinboard(name: " 工作 ", color: .blue)
        let code = try store.createPinboard(name: "代码", color: .green)

        #expect(work.name == "工作")
        #expect(try store.pinboards() == [work, code])

        try store.renamePinboard(work.id, to: "项目")
        try store.renamePinboard(code.id, to: "  ")
        try store.setColor(.red, ofPinboard: code.id)
        #expect(try store.pinboards().map(\.name) == ["项目", "代码"])
        #expect(try store.pinboards().last?.color == .red)
    }

    @Test func newPinsGoFirstAndPinningTwiceKeepsThePosition() throws {
        let board = try store.createPinboard(name: "工作", color: .blue)
        let a = try insert("a", at: 1)
        let b = try insert("b", at: 2)

        #expect(try store.pin(a, to: board.id))
        #expect(try store.pin(b, to: board.id))
        #expect(try !store.pin(a, to: board.id))

        #expect(try previews(in: board) == ["b", "a"])
        #expect(try store.items().first { $0.id == a }?.pinboardIDs == [board.id])
    }

    @Test func reorderingAndCopyingAgainKeepTheOrder() throws {
        let board = try store.createPinboard(name: "工作", color: .blue)
        let a = try insert("a", at: 1)
        let b = try insert("b", at: 2)
        let c = try insert("c", at: 3)
        for id in [a, b, c] { try store.pin(id, to: board.id) }

        try store.setOrder([a, c, b], inPinboard: board.id)
        #expect(try previews(in: board) == ["a", "c", "b"])

        // 再复制一次 b：历史里排到最前，Pinboard 里不动。
        try store.insert(ClipContent(kind: .text, text: "b"), source: nil, at: Date(timeIntervalSince1970: 9))
        #expect(try store.items().first?.preview == "b")
        #expect(try previews(in: board) == ["a", "c", "b"])
    }

    @Test func searchAndFiltersWorkInsideAPinboard() throws {
        let board = try store.createPinboard(name: "工作", color: .blue)
        let other = try store.createPinboard(name: "其他", color: .red)
        let a = try insert("apple", at: 1)
        let b = try insert("banana", at: 2)
        try insert("avocado", at: 3)
        try store.pin(a, to: board.id)
        try store.pin(b, to: board.id)
        try store.pin(b, to: other.id)

        #expect(try store.items(matching: ClipQuery(text: "a", pinboardID: board.id)).map(\.preview) == ["banana", "apple"])
        #expect(try store.items(matching: ClipQuery(inPinboards: [other.id])).map(\.preview) == ["banana"])
        #expect(try store.items(matching: ClipQuery(inPinboards: [board.id, other.id])).map(\.preview) == ["banana", "apple"])
    }

    @Test func clearingHistoryKeepsPinnedEntriesAndTheirOrder() throws {
        let board = try store.createPinboard(name: "工作", color: .blue)
        let a = try insert("a", at: 1)
        let b = try insert("b", at: 2)
        try insert("loose", at: 3)
        try store.pin(a, to: board.id)
        try store.pin(b, to: board.id)
        try store.setOrder([a, b], inPinboard: board.id)
        #expect(try store.pinnedCount() == 2)

        try store.clearHistory()

        #expect(try store.count() == 2)
        #expect(try previews(in: board) == ["a", "b"])
        #expect(try store.pinboards() == [board])
    }

    @Test func deletingAPinboardKeepsItsEntriesInHistory() throws {
        let board = try store.createPinboard(name: "工作", color: .blue)
        let a = try insert("a", at: 1)
        try store.pin(a, to: board.id)

        try store.deletePinboard(board.id)

        #expect(try store.pinboards().isEmpty)
        #expect(try store.items().map(\.preview) == ["a"])
        #expect(try store.items().first?.pinboardIDs.isEmpty == true)
    }

    @Test func unpinAndUndoPutTheEntryBackInItsPlace() throws {
        let board = try store.createPinboard(name: "工作", color: .blue)
        let a = try insert("a", at: 1)
        let b = try insert("b", at: 2)
        let c = try insert("c", at: 3)
        for id in [a, b, c] { try store.pin(id, to: board.id) }
        try store.setOrder([a, b, c], inPinboard: board.id)

        let removed = try #require(try store.unpin(b, from: board.id))
        #expect(try previews(in: board) == ["a", "c"])
        #expect(try store.count() == 3)
        #expect(try store.unpin(b, from: board.id) == nil)

        try store.restorePin(removed)
        #expect(try previews(in: board) == ["a", "b", "c"])
    }

    @Test func deletingAPinnedEntryAndUndoingRestoresItsPins() throws {
        let board = try store.createPinboard(name: "工作", color: .blue)
        let a = try insert("a", at: 1)
        let b = try insert("b", at: 2)
        try store.pin(a, to: board.id)
        try store.pin(b, to: board.id)
        try store.setOrder([a, b], inPinboard: board.id)
        try store.setTitle("标题", id: a)

        let deleted = try #require(try store.delete(id: a))
        #expect(try previews(in: board) == ["b"])

        #expect(try store.restore(deleted) == a)
        #expect(try previews(in: board) == ["a", "b"])
        #expect(try store.item(id: a)?.title == "标题")
    }

    @Test func undoingAfterThePinboardIsGoneOnlyRestoresTheEntry() throws {
        let board = try store.createPinboard(name: "工作", color: .blue)
        let a = try insert("a", at: 1)
        try store.pin(a, to: board.id)
        let deleted = try #require(try store.delete(id: a))
        try store.deletePinboard(board.id)

        #expect(try store.restore(deleted) == a)
        #expect(try store.item(id: a)?.pinboardIDs.isEmpty == true)
    }

    @Test func historyPositionCountsNewerEntries() throws {
        let a = try insert("a", at: 1)
        let b = try insert("b", at: 2)
        try insert("c", at: 3)

        #expect(try store.historyPosition(of: a) == 2)
        #expect(try store.historyPosition(of: b) == 1)
        #expect(try store.historyPosition(of: 42) == nil)
    }

    @Test func nextColorCyclesThroughThePalette() {
        #expect(PinboardColor.next(after: []) == .red)
        let one = [Pinboard(id: 1, name: "a", color: .red)]
        #expect(PinboardColor.next(after: one) == .orange)
    }
}
