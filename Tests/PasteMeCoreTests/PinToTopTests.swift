import Foundation
import Testing
@testable import PasteMeCore

/// 置顶（#77）：条目排在历史里所有没置顶的条目前面，不进 Pinboard；取消后回到按时间的位置。
@Suite struct PinToTopTests {
    let store: ClipStore

    init() throws {
        store = try ClipStore(path: ":memory:")
    }

    @discardableResult
    private func insert(_ text: String, at time: TimeInterval) throws -> Int64 {
        try store.insert(ClipContent(kind: .text, text: text), source: nil, at: Date(timeIntervalSince1970: time))
    }

    private func previews(_ query: ClipQuery = ClipQuery(limit: 100)) throws -> [String?] {
        try store.items(matching: query).map(\.preview)
    }

    @Test func pinnedEntryStaysFirstUntilUnpinned() throws {
        let old = try insert("old", at: 1)
        try insert("middle", at: 2)
        try store.setPinnedToTop(true, id: old, at: Date(timeIntervalSince1970: 3))
        try insert("newer", at: 4)

        #expect(try previews() == ["old", "newer", "middle"])
        let item = try #require(try store.item(id: old))
        #expect(item.pinnedToTopAt == Date(timeIntervalSince1970: 3))
        #expect(item.pinboardIDs.isEmpty)

        try store.setPinnedToTop(false, id: old)
        #expect(try previews() == ["newer", "middle", "old"])
        #expect(try store.item(id: old)?.pinnedToTopAt == nil)
    }

    @Test func pinnedEntriesAreOrderedByWhenTheyWerePinned() throws {
        let a = try insert("a", at: 1)
        let b = try insert("b", at: 2)
        try insert("c", at: 3)
        try store.setPinnedToTop(true, id: b, at: Date(timeIntervalSince1970: 10))
        try store.setPinnedToTop(true, id: a, at: Date(timeIntervalSince1970: 11))

        #expect(try previews() == ["a", "b", "c"])
    }

    @Test func pinningAgainKeepsTheOriginalPinTime() throws {
        let a = try insert("a", at: 1)
        let b = try insert("b", at: 2)
        try store.setPinnedToTop(true, id: a, at: Date(timeIntervalSince1970: 10))
        try store.setPinnedToTop(true, id: b, at: Date(timeIntervalSince1970: 11))
        try store.setPinnedToTop(true, id: a, at: Date(timeIntervalSince1970: 12))

        #expect(try previews() == ["b", "a"])
    }

    @Test func copyingAPinnedEntryAgainKeepsItPinned() throws {
        let a = try insert("a", at: 1)
        try store.setPinnedToTop(true, id: a, at: Date(timeIntervalSince1970: 2))
        try insert("b", at: 3)
        try insert("a", at: 4)

        #expect(try previews() == ["a", "b"])
        #expect(try store.item(id: a)?.pinnedToTopAt == Date(timeIntervalSince1970: 2))
    }

    @Test func searchAndFiltersAlsoPutPinnedEntriesFirst() throws {
        let old = try insert("apple old", at: 1)
        try insert("apple new", at: 2)
        try insert("banana", at: 3)
        try store.setPinnedToTop(true, id: old)

        #expect(try previews(ClipQuery(text: "apple")) == ["apple old", "apple new"])
        #expect(try previews(ClipQuery(kinds: [.text])) == ["apple old", "banana", "apple new"])
    }

    @Test func pinboardOrderIgnoresPinToTop() throws {
        let board = try store.createPinboard(name: "工作", color: .blue)
        let a = try insert("a", at: 1)
        let b = try insert("b", at: 2)
        try store.pin(a, to: board.id)
        try store.pin(b, to: board.id)
        try store.setOrder([a, b], inPinboard: board.id)
        try store.setPinnedToTop(true, id: b)

        #expect(try previews(ClipQuery(pinboardID: board.id)) == ["a", "b"])
    }

    @Test func historyPositionCountsPinnedEntriesFirst() throws {
        let a = try insert("a", at: 1)
        let b = try insert("b", at: 2)
        let c = try insert("c", at: 3)
        try store.setPinnedToTop(true, id: a)

        #expect(try store.historyPosition(of: a) == 0)
        #expect(try store.historyPosition(of: c) == 1)
        #expect(try store.historyPosition(of: b) == 2)
    }

    /// 名次和列表用同一套规则：置顶时间是多少（哪怕早于 1970 年）都排在没置顶的前面。
    @Test func historyPositionMatchesTheListForAnyPinTime() throws {
        let a = try insert("a", at: 1)
        let b = try insert("b", at: 2)
        try store.setPinnedToTop(true, id: a, at: Date(timeIntervalSince1970: -2))

        #expect(try previews() == ["a", "b"])
        #expect(try store.historyPosition(of: a) == 0)
        #expect(try store.historyPosition(of: b) == 1)
    }

    /// 在搜索结果里排第几：只数命中的条目，不看读取条数；没命中时为 nil。
    @Test func positionCountsOnlyMatchingEntries() throws {
        let old = try insert("apple old", at: 1)
        try insert("banana", at: 2)
        let new = try insert("apple new", at: 3)
        let banana = try store.items().first { $0.preview == "banana" }!.id

        #expect(try store.position(of: old, matching: ClipQuery(text: "apple", limit: 1)) == 1)
        #expect(try store.position(of: new, matching: ClipQuery(text: "apple")) == 0)
        #expect(try store.position(of: banana, matching: ClipQuery(text: "apple")) == nil)
        try store.setPinnedToTop(true, id: old)
        #expect(try store.position(of: old, matching: ClipQuery(text: "apple")) == 0)
        #expect(try store.pinnedToTopCount() == 1)
    }

    @Test func clearingAndAutoCleanupKeepPinnedEntries() throws {
        let pinned = try insert("pinned", at: 1)
        try insert("loose", at: 2)
        try store.setPinnedToTop(true, id: pinned)
        let cutoff = Date(timeIntervalSince1970: 10)

        #expect(try store.keptCount() == 1)
        #expect(try store.unpinnedCount(before: cutoff) == 1)
        #expect(try store.deleteUnpinned(before: cutoff) == 1)
        #expect(try previews() == ["pinned"])

        try insert("loose again", at: 3)
        try store.clearHistory()
        #expect(try previews() == ["pinned"])
    }

    @Test func keptCountCountsEachEntryOnce() throws {
        let board = try store.createPinboard(name: "工作", color: .blue)
        let both = try insert("both", at: 1)
        let pinnedOnly = try insert("pinboard", at: 2)
        try insert("loose", at: 3)
        try store.pin(both, to: board.id)
        try store.pin(pinnedOnly, to: board.id)
        try store.setPinnedToTop(true, id: both)

        #expect(try store.keptCount() == 2)
    }

    @Test func undoingADeleteRestoresPinToTop() throws {
        let a = try insert("a", at: 1)
        try insert("b", at: 2)
        try store.setPinnedToTop(true, id: a, at: Date(timeIntervalSince1970: 5))
        let deleted = try #require(try store.delete(id: a))
        try store.restore(deleted)

        #expect(try previews() == ["a", "b"])
        #expect(try store.item(id: a)?.pinnedToTopAt == Date(timeIntervalSince1970: 5))
    }

    @Test func editingIntoAPinnedDuplicateKeepsThePin() throws {
        let pinned = try insert("same", at: 1)
        let edited = try insert("draft", at: 2)
        try insert("other", at: 3)
        try store.setPinnedToTop(true, id: pinned, at: Date(timeIntervalSince1970: 4))

        #expect(try store.updateText("same", rtf: nil, id: edited))

        #expect(try store.item(id: pinned) == nil)
        #expect(try store.item(id: edited)?.pinnedToTopAt == Date(timeIntervalSince1970: 4))
        #expect(try previews() == ["same", "other"])
    }
}
