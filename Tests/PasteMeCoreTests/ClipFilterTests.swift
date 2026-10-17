import Foundation
import Testing
@testable import PasteMeCore

/// `ClipQuery` 的类型、来源应用、时间筛选，以及搜索框语法（#4）。
@Suite struct ClipFilterTests {
    let store: ClipStore
    static let notes = ClipSource(bundleID: "com.apple.Notes", name: "备忘录")
    static let wechat = ClipSource(bundleID: "com.tencent.xinWeChat", name: "微信")

    init() throws {
        store = try ClipStore(path: ":memory:")
    }

    private func previews(_ query: ClipQuery) throws -> [String?] {
        try store.items(matching: query).map(\.preview)
    }

    @Test func kindsKeepOnlyThoseTypes() throws {
        try store.insert(ClipContent(kind: .text, text: "note"), source: nil, at: Date(timeIntervalSince1970: 1))
        try store.insert(ClipContent(kind: .link, text: "https://example.com"), source: nil, at: Date(timeIntervalSince1970: 2))
        try store.insert(ClipContent(kind: .file, text: "/tmp/a.txt"), source: nil, at: Date(timeIntervalSince1970: 3))

        #expect(try previews(ClipQuery(kinds: [.link])) == ["https://example.com"])
        #expect(try previews(ClipQuery(kinds: [.text, .file])) == ["/tmp/a.txt", "note"])
        #expect(try previews(ClipQuery(kinds: [])).isEmpty)
        #expect(try previews(ClipQuery(kinds: nil)).count == 3)
    }

    @Test func sourceAppMatchesBundleIDOrNamePart() throws {
        try store.insert(ClipContent(kind: .text, text: "from notes"), source: Self.notes)
        try store.insert(ClipContent(kind: .text, text: "from wechat"), source: Self.wechat)
        try store.insert(ClipContent(kind: .text, text: "unknown"), source: nil)

        #expect(try previews(ClipQuery(sourceBundleID: "com.tencent.xinWeChat")) == ["from wechat"])
        #expect(try previews(ClipQuery(sourceName: "备忘")) == ["from notes"])
    }

    @Test func timeBoundsIncludeStartAndExcludeEnd() throws {
        for second in [10.0, 20, 30] {
            try store.insert(ClipContent(kind: .text, text: "at \(Int(second))"), source: nil, at: Date(timeIntervalSince1970: second))
        }

        let query = ClipQuery(createdFrom: Date(timeIntervalSince1970: 20), createdBefore: Date(timeIntervalSince1970: 30))
        #expect(try previews(query) == ["at 20"])
        #expect(try previews(ClipQuery(createdFrom: Date(timeIntervalSince1970: 15))) == ["at 30", "at 20"])
    }

    @Test func allConditionsMustMatch() throws {
        try store.insert(ClipContent(kind: .text, text: "invoice draft"), source: Self.notes, at: Date(timeIntervalSince1970: 100))
        try store.insert(ClipContent(kind: .text, text: "invoice sent"), source: Self.wechat, at: Date(timeIntervalSince1970: 200))
        try store.insert(ClipContent(kind: .link, text: "https://invoice.example.com"), source: Self.wechat, at: Date(timeIntervalSince1970: 300))
        try store.insert(ClipContent(kind: .text, text: "invoice old"), source: Self.wechat, at: Date(timeIntervalSince1970: 50))

        let query = ClipQuery(
            text: "invoice",
            kinds: [.text],
            sourceBundleID: Self.wechat.bundleID,
            createdFrom: Date(timeIntervalSince1970: 60)
        )
        #expect(try previews(query) == ["invoice sent"])
    }

    @Test func restrictingIntersectsKinds() {
        #expect(ClipQuery().restricting(to: [.image]).kinds == [.image])
        #expect(ClipQuery(kinds: [.image, .file]).restricting(to: [.file, .text]).kinds == [.file])
        #expect(ClipQuery(kinds: [.image]).restricting(to: [.text]).kinds == [])
        #expect(ClipQuery(kinds: [.image]).restricting(to: nil).kinds == [.image])
    }

    @Test func parseTurnsTypeAndAppWordsIntoFilters() {
        let query = ClipQuery.parse("发票 type:图片 app:微信  草稿")
        #expect(query.text == "发票 草稿")
        #expect(query.kinds == [.image])
        #expect(query.sourceName == "微信")
    }

    @Test func parseAcceptsEnglishPrefixesChineseKeysAndFullWidthColons() {
        #expect(ClipQuery.parse("type:im").kinds == [.image])
        #expect(ClipQuery.parse("TYPE:Link").kinds == [.link])
        #expect(ClipQuery.parse("类型：文件").kinds == [.file])
        #expect(ClipQuery.parse("应用：备忘录").sourceName == "备忘录")
        // “文”既是文本也是文件的开头。
        #expect(ClipQuery.parse("type:文").kinds == [.text, .file])
        #expect(ClipQuery.parse("type:text type:link").kinds == [.text, .link])
    }

    @Test func parseKeepsUnrecognizedWordsAsText() {
        #expect(ClipQuery.parse("type:pdf").text == "type:pdf")
        #expect(ClipQuery.parse("type:pdf").kinds == nil)
        #expect(ClipQuery.parse("https://example.com").text == "https://example.com")
        #expect(ClipQuery.parse("10:30 会议").text == "10:30 会议")
        // 刚输入完冒号、还没写值时不筛选，也不按这个词搜索。
        #expect(ClipQuery.parse("会议 type:") == ClipQuery(text: "会议"))
        #expect(ClipQuery.parse("app:") == ClipQuery())
    }

    @Test func mentionIsTheLastWordWhenItStartsWithAt() {
        #expect(FilterMention(in: "@") == FilterMention(text: "", remainder: ""))
        #expect(FilterMention(in: "报销 @wx") == FilterMention(text: "wx", remainder: "报销 "))
        #expect(FilterMention(in: "＠微信") == FilterMention(text: "微信", remainder: ""))
        // 写完了（后面打了空格），或者 @ 不在词首，例如邮箱地址。
        #expect(FilterMention(in: "@wx ") == nil)
        #expect(FilterMention(in: "@wx 报销") == nil)
        #expect(FilterMention(in: "a@b.com") == nil)
        #expect(FilterMention(in: "@a@b") == nil)
        #expect(FilterMention(in: "报销") == nil)
    }

    @Test func kindsMatchingAPrefixOfTheirNames() {
        #expect(ClipKind.matching("") == ClipKind.allCases)
        #expect(ClipKind.matching("IM") == [.image])
        #expect(ClipKind.matching("文") == [.text, .file])
        #expect(ClipKind.matching("微信").isEmpty)
    }

    @Test func timeRangesFollowCalendarDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        // 2026-10-16 15:00 北京时间。
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 15)))
        func day(_ d: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: d)))
        }

        #expect(TimeRange.all.bounds(now: now, calendar: calendar) == (nil, nil))
        #expect(TimeRange.today.bounds(now: now, calendar: calendar) == (try day(16), nil))
        #expect(TimeRange.yesterday.bounds(now: now, calendar: calendar) == (try day(15), try day(16)))
        #expect(TimeRange.last7Days.bounds(now: now, calendar: calendar) == (try day(10), nil))
        #expect(TimeRange.last30Days.bounds(now: now, calendar: calendar).from == calendar.date(from: DateComponents(year: 2026, month: 9, day: 17)))
    }

    @Test func sourceAppsAreSortedByEntryCountWithLatestName() throws {
        try store.insert(ClipContent(kind: .text, text: "1"), source: Self.notes, at: Date(timeIntervalSince1970: 1))
        try store.insert(ClipContent(kind: .text, text: "2"), source: Self.wechat, at: Date(timeIntervalSince1970: 2))
        try store.insert(ClipContent(kind: .text, text: "3"), source: ClipSource(bundleID: "com.tencent.xinWeChat", name: "WeChat"), at: Date(timeIntervalSince1970: 3))
        try store.insert(ClipContent(kind: .text, text: "4"), source: nil, at: Date(timeIntervalSince1970: 4))

        #expect(try store.sourceApps() == [
            SourceApp(bundleID: "com.tencent.xinWeChat", name: "WeChat", count: 2),
            SourceApp(bundleID: "com.apple.Notes", name: "备忘录", count: 1),
        ])
    }

    /// ADR 0003：10,000 条条目时，主线程上的查询要在 50ms 以内。
    @Test func filteredSearchOverTenThousandItemsIsFast() throws {
        let sources = [Self.notes, Self.wechat, ClipSource(bundleID: "com.apple.Safari", name: "Safari")]
        let kinds: [ClipKind] = [.text, .text, .link, .file]
        for i in 0..<10_000 {
            let kind = kinds[i % kinds.count]
            let text = kind == .link ? "https://example.com/\(i)" : "条目 \(i) 一些用来搜索的文字 invoice-\(i % 97)"
            try store.insert(ClipContent(kind: kind, text: text), source: sources[i % sources.count], at: Date(timeIntervalSince1970: Double(i)))
        }

        let queries = [
            ClipQuery(text: "invoice-42"),
            ClipQuery(text: "invoice", kinds: [.text], sourceBundleID: "com.tencent.xinWeChat"),
            ClipQuery(text: "不存在的词"),
            ClipQuery.parse("type:link app:saf example"),
            ClipQuery(createdFrom: Date(timeIntervalSince1970: 9_000)),
            ClipQuery.parse("wechat app:saf").resolvingAppNames { _ in ["com.tencent.xinWeChat", "com.apple.Safari"] },
        ]
        for query in queries {
            let start = Date()
            _ = try store.items(matching: query)
            let elapsed = Date().timeIntervalSince(start)
            #expect(elapsed < 0.05, "\(query) 用了 \(Int(elapsed * 1000))ms")
        }
        let start = Date()
        _ = try store.sourceApps()
        #expect(Date().timeIntervalSince(start) < 0.05)
    }
}

/// 打开旧版本数据库时的迁移。
@Suite struct ClipStoreMigrationTests {
    @Test func versionOneDatabaseKeepsItsEntries() throws {
        let dir = try ClipStoreTests.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("history.sqlite").path

        // 0.1.0 建的表（user_version = 1）。
        let old = try SQLiteDatabase(path: path)
        try old.execute("""
            CREATE TABLE clips (
                id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, text TEXT, rtf BLOB, image BLOB,
                thumbnail BLOB, source_bundle_id TEXT, source_name TEXT, content_hash TEXT NOT NULL UNIQUE,
                created_at REAL NOT NULL
            );
            CREATE INDEX clips_created_at ON clips (created_at DESC);
            INSERT INTO clips (kind, text, source_bundle_id, source_name, content_hash, created_at)
                VALUES ('text', 'old entry', 'com.apple.Notes', '备忘录', 'hash-1', 1);
            PRAGMA user_version = 1;
            """)

        let store = try ClipStore(path: path)
        #expect(try old.userVersion == 6)
        #expect(try store.items().map(\.preview) == ["old entry"])
        #expect(try store.items(matching: ClipQuery(sourceBundleID: "com.apple.Notes")).count == 1)
        // 迁移加上的 ocr_text 列为 NULL，旧条目照常能搜到。
        #expect(try store.items().first?.recognizedText == nil)
        #expect(try store.items(matching: ClipQuery(text: "old")).count == 1)
        #expect(try store.insert(ClipContent(kind: .text, text: "new"), source: nil) > 1)
    }

    @Test func versionThreeDatabaseGainsTitlesLinkPreviewsAndPinboards() throws {
        let dir = try ClipStoreTests.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("history.sqlite").path

        // #5 之后的表结构（user_version = 3）。
        let old = try SQLiteDatabase(path: path)
        try old.execute("""
            CREATE TABLE clips (
                id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, text TEXT, rtf BLOB, image BLOB,
                thumbnail BLOB, source_bundle_id TEXT, source_name TEXT, content_hash TEXT NOT NULL UNIQUE,
                created_at REAL NOT NULL, ocr_text TEXT
            );
            CREATE INDEX clips_created_at ON clips (created_at DESC);
            CREATE INDEX clips_source_bundle_id ON clips (source_bundle_id);
            INSERT INTO clips (kind, text, content_hash, created_at, ocr_text)
                VALUES ('link', 'https://example.com', 'hash-1', 1, NULL);
            PRAGMA user_version = 3;
            """)

        let store = try ClipStore(path: path)
        #expect(try old.userVersion == 6)
        let item = try #require(try store.items().first)
        #expect(item.preview == "https://example.com")
        #expect(item.title == nil && item.linkTitle == nil && item.pinboardIDs.isEmpty)
        #expect(try store.linkPreviewURL(id: item.id) == URL(string: "https://example.com"))

        let board = try store.createPinboard(name: "工作", color: .blue)
        try store.pin(item.id, to: board.id)
        try store.setTitle("示例网站", id: item.id)
        #expect(try store.items(matching: ClipQuery(pinboardID: board.id)).map(\.title) == ["示例网站"])
    }
}
