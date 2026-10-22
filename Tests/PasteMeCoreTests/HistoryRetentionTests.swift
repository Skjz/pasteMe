import Foundation
import Testing
@testable import PasteMeCore

/// 自动清除一段时间前的历史（#34）：Pinboard 里的条目保留，按最后一次使用的时间算。
@Suite struct HistoryRetentionTests {
    let store: ClipStore
    static let day: TimeInterval = 24 * 60 * 60
    let now = Date(timeIntervalSince1970: 100 * day)

    init() throws {
        store = try ClipStore(path: ":memory:")
    }

    @discardableResult
    private func insert(_ text: String, daysAgo: Double) throws -> Int64 {
        try store.insert(ClipContent(kind: .text, text: text), source: nil, at: now.addingTimeInterval(-daysAgo * Self.day))
    }

    private func texts() throws -> [String?] {
        try store.items(matching: ClipQuery(limit: 100)).map(\.preview)
    }

    @Test func deletesOnlyUnpinnedEntriesOlderThanTheCutoff() throws {
        try insert("昨天", daysAgo: 1)
        try insert("8 天前", daysAgo: 8)
        let pinned = try insert("8 天前、固定了", daysAgo: 8)
        try store.pin(pinned, to: try store.createPinboard(name: "工作", color: .blue).id)
        let cutoff = try #require(HistoryRetention.week.cutoff(now: now))

        #expect(try store.unpinnedCount(before: cutoff) == 1)
        #expect(try store.deleteUnpinned(before: cutoff) == 1)
        #expect(try texts() == ["昨天", "8 天前、固定了"])
        #expect(try store.deleteUnpinned(before: cutoff) == 0)
    }

    @Test func theCutoffIsExclusive() throws {
        let cutoff = try #require(HistoryRetention.week.cutoff(now: now))
        try store.insert(ClipContent(kind: .text, text: "早一秒"), source: nil, at: cutoff.addingTimeInterval(-1))
        try store.insert(ClipContent(kind: .text, text: "正好"), source: nil, at: cutoff)
        try store.insert(ClipContent(kind: .text, text: "晚一秒"), source: nil, at: cutoff.addingTimeInterval(1))

        try store.deleteUnpinned(before: cutoff)
        #expect(try texts() == ["晚一秒", "正好"])
    }

    @Test func entriesUsedRecentlyAreKept() throws {
        let pasted = try insert("8 天前复制、昨天粘贴过", daysAgo: 8)
        try store.touch(id: pasted, at: now.addingTimeInterval(-Self.day))
        try insert("8 天前复制、今天又复制了一次", daysAgo: 8)
        try insert("8 天前复制、今天又复制了一次", daysAgo: 0)

        try store.deleteUnpinned(before: try #require(HistoryRetention.week.cutoff(now: now)))
        #expect(try texts() == ["8 天前复制、今天又复制了一次", "8 天前复制、昨天粘贴过"])
    }

    @Test func presetsStartAtAWeekAndNeverMeansNoCutoff() {
        #expect(HistoryRetention.allCases.compactMap(\.days) == [7, 30, 90, 365])
        #expect(HistoryRetention.never.cutoff(now: now) == nil)
        #expect(HistoryRetention.month.cutoff(now: now) == now.addingTimeInterval(-30 * Self.day))
    }
}
