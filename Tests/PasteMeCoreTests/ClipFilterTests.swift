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

    @Test func textSubtypesKeepOnlyThoseTextEntries() throws {
        try store.insert(ClipContent(kind: .text, text: "note"), source: nil, at: Date(timeIntervalSince1970: 1))
        try store.insert(ClipContent(kind: .text, text: "1760688000"), source: nil, at: Date(timeIntervalSince1970: 2))
        try store.insert(ClipContent(kind: .text, text: "SGVsbG8sIOS4lueVjA=="), source: nil, at: Date(timeIntervalSince1970: 3))
        try store.insert(ClipContent(kind: .text, text: "#ff8800"), source: nil, at: Date(timeIntervalSince1970: 4))
        try store.insert(ClipContent(kind: .link, text: "https://example.com"), source: nil, at: Date(timeIntervalSince1970: 5))

        #expect(try previews(ClipQuery(textSubtypes: [.timestamp])) == ["1760688000"])
        #expect(try previews(ClipQuery(textSubtypes: [.base64, .color])) == ["#ff8800", "SGVsbG8sIOS4lueVjA=="])
        #expect(try previews(ClipQuery(textSubtypes: [])).isEmpty)
        // 按「文本」筛选时包含所有子类型。
        #expect(try previews(ClipQuery(kinds: [.text])).count == 4)
        #expect(try store.items(matching: ClipQuery(textSubtypes: [.color])).first?.textSubtype == .color)
        #expect(ClipQuery(textSubtypes: [.hex, .base64]).restricting(toSubtypes: [.hex]).textSubtypes == [.hex])
    }

    @Test func parseAcceptsTextSubtypesAfterType() {
        #expect(ClipQuery.parse("type:base64 abc").textSubtypes == [.base64])
        #expect(ClipQuery.parse("type:base64 abc").text == "abc")
        #expect(ClipQuery.parse("类型:时间戳").textSubtypes == [.timestamp])
        #expect(ClipQuery.parse("type:hex").textSubtypes == [.hexdump, .hex])
        // 同时对得上类型时只按类型筛选：子类型都是文本。
        #expect(ClipQuery.parse("type:t").kinds == [.text])
        #expect(ClipQuery.parse("type:t").textSubtypes == nil)
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
            var text = kind == .link ? "https://example.com/\(i)" : "条目 \(i) 一些用来搜索的文字 invoice-\(i % 97)"
            if kind == .text, i % 10 == 0 { text = "\(1_760_000_000 + i)" }
            try store.insert(ClipContent(kind: kind, text: text), source: sources[i % sources.count], at: Date(timeIntervalSince1970: Double(i)))
        }

        let queries = [
            ClipQuery(text: "invoice-42"),
            ClipQuery(text: "invoice", kinds: [.text], sourceBundleID: "com.tencent.xinWeChat"),
            ClipQuery(text: "不存在的词"),
            ClipQuery.parse("type:link app:saf example"),
            ClipQuery(createdFrom: Date(timeIntervalSince1970: 9_000)),
            ClipQuery.parse("wechat app:saf").resolvingAppNames { _ in ["com.tencent.xinWeChat", "com.apple.Safari"] },
            ClipQuery(textSubtypes: [.timestamp]),
            ClipQuery(text: "17600", textSubtypes: [.timestamp, .code], sourceBundleID: "com.apple.Notes"),
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
        #expect(try old.userVersion == 9)
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
        #expect(try old.userVersion == 9)
        let item = try #require(try store.items().first)
        #expect(item.preview == "https://example.com")
        #expect(item.title == nil && item.linkTitle == nil && item.pinboardIDs.isEmpty)
        #expect(try store.linkPreviewURL(id: item.id) == URL(string: "https://example.com"))

        let board = try store.createPinboard(name: "工作", color: .blue)
        try store.pin(item.id, to: board.id)
        try store.setTitle("示例网站", id: item.id)
        #expect(try store.items(matching: ClipQuery(pinboardID: board.id)).map(\.title) == ["示例网站"])
    }

    @Test func versionSixDatabaseBackfillsTextSubtypesInBatches() throws {
        let dir = try ClipStoreTests.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("history.sqlite").path

        let old = try ClipStore(path: path)
        for (i, text) in ["1760688000", "hello", "#ff8800", "SGVsbG8sIOS4lueVjA=="].enumerated() {
            try old.insert(ClipContent(kind: .text, text: text), source: nil, at: Date(timeIntervalSince1970: Double(i)))
        }
        try old.insert(ClipContent(kind: .link, text: "https://example.com"), source: nil, at: Date(timeIntervalSince1970: 9))
        // 退回第 6 版：去掉子类型列（和第 8 版加的置顶列）。
        let raw = try SQLiteDatabase(path: path)
        try raw.execute("""
            DROP INDEX clips_pinned_top; ALTER TABLE clips DROP COLUMN pinned_top_at;
            ALTER TABLE clips DROP COLUMN text_subtype; PRAGMA user_version = 6;
            """)

        let store = try ClipStore(path: path)
        #expect(try raw.userVersion == 9)
        #expect(try store.items().allSatisfy { $0.textSubtype == nil })
        #expect(try store.backfillTextSubtypes(limit: 3) == 3)
        #expect(try store.backfillTextSubtypes(limit: 3) == 1)
        #expect(try store.backfillTextSubtypes(limit: 3) == 0)
        #expect(try store.items(matching: ClipQuery(kinds: [.text])).map(\.textSubtype) == [.base64, .color, nil, .timestamp])
    }

    @Test func versionSevenDatabaseGainsPinToTop() throws {
        let dir = try ClipStoreTests.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("history.sqlite").path

        let old = try ClipStore(path: path)
        let first = try old.insert(ClipContent(kind: .text, text: "first"), source: nil, at: Date(timeIntervalSince1970: 1))
        try old.insert(ClipContent(kind: .text, text: "second"), source: nil, at: Date(timeIntervalSince1970: 2))
        // 退回第 7 版：去掉置顶列和它的索引。
        let raw = try SQLiteDatabase(path: path)
        try raw.execute("DROP INDEX clips_pinned_top; ALTER TABLE clips DROP COLUMN pinned_top_at; PRAGMA user_version = 7;")

        let store = try ClipStore(path: path)
        #expect(try raw.userVersion == 9)
        #expect(try store.items().map(\.preview) == ["second", "first"])
        #expect(try store.items().allSatisfy { $0.pinnedToTopAt == nil })
        try store.setPinnedToTop(true, id: first)
        #expect(try store.items().map(\.preview) == ["first", "second"])
    }

    /// 第 9 版把图片、RTF、缩略图、网站图标这些大块数据挪到每一行的最后（#89）。SQLite 读一列时要先走过它前面的列，
    /// 大块数据放在搜索的列前面时，搜索每一条图片都要把整张图片从磁盘读一遍：5000 条的历史里没命中的搜索要 50 ms。
    /// 以后用 `ALTER TABLE ADD COLUMN` 加的列会排在大块数据后面，这个测试会失败：按第 9 版的做法重建表，把新列放到前面。
    @Test func largeColumnsComeLastInEveryRow() throws {
        let dir = try ClipStoreTests.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("history.sqlite").path
        _ = try ClipStore(path: path)

        let raw = try SQLiteDatabase(path: path)
        let statement = try raw.prepare("SELECT name, type FROM pragma_table_info('clips') ORDER BY cid")
        var columns: [(name: String, type: String)] = []
        while try statement.step() {
            columns.append((statement.text(0) ?? "", statement.text(1) ?? ""))
        }
        let large = ["thumbnail", "link_icon", "rtf", "image"]
        #expect(Array(columns.suffix(large.count).map(\.name)) == large)
        #expect(columns.dropLast(large.count).allSatisfy { $0.type != "BLOB" })
    }

    /// 从第 8 版升级时整张表重建（#89）：条目、id、Pinboard 里的位置、置顶、索引都不变，
    /// 删掉的最大 id 也不会被新条目再用（撤销删除要用原来的 id 放回去）。
    @Test func versionEightDatabaseIsRebuiltWithLargeColumnsLast() throws {
        let dir = try ClipStoreTests.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("history.sqlite").path

        // 第 8 版的表结构：大块数据在中间，后来加的列在最后。
        let old = try SQLiteDatabase(path: path)
        try old.execute("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE clips (
                id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, text TEXT, rtf BLOB, image BLOB,
                thumbnail BLOB, source_bundle_id TEXT, source_name TEXT, content_hash TEXT NOT NULL UNIQUE,
                created_at REAL NOT NULL, ocr_text TEXT, title TEXT, link_title TEXT, link_icon BLOB,
                text_subtype TEXT, pinned_top_at REAL
            );
            CREATE INDEX clips_created_at ON clips (created_at DESC);
            CREATE INDEX clips_source_bundle_id ON clips (source_bundle_id);
            CREATE INDEX clips_pinned_top ON clips (pinned_top_at DESC, created_at DESC);
            CREATE TABLE pinboards (
                id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, color TEXT NOT NULL, sort_order INTEGER NOT NULL
            );
            CREATE TABLE pinboard_items (
                pinboard_id INTEGER NOT NULL REFERENCES pinboards (id) ON DELETE CASCADE,
                clip_id INTEGER NOT NULL REFERENCES clips (id) ON DELETE CASCADE,
                sort_order INTEGER NOT NULL,
                PRIMARY KEY (pinboard_id, clip_id)
            );
            CREATE INDEX pinboard_items_clip_id ON pinboard_items (clip_id);
            INSERT INTO clips (id, kind, text, source_bundle_id, source_name, content_hash, created_at, text_subtype)
                VALUES (1, 'text', 'hello', 'com.apple.Notes', '备忘录', 'hash-1', 1, '');
            INSERT INTO clips (id, kind, image, thumbnail, content_hash, created_at, ocr_text, title, pinned_top_at)
                VALUES (2, 'image', x'89504E47', x'FFD8', 'hash-2', 2, '发票', '截图', 5);
            INSERT INTO clips (id, kind, text, content_hash, created_at) VALUES (7, 'text', 'deleted', 'hash-7', 3);
            DELETE FROM clips WHERE id = 7;
            INSERT INTO pinboards (name, color, sort_order) VALUES ('工作', 'blue', 0);
            INSERT INTO pinboard_items (pinboard_id, clip_id, sort_order) VALUES (1, 1, 1), (1, 2, 0);
            PRAGMA user_version = 8;
            """)

        let store = try ClipStore(path: path)
        #expect(try old.userVersion == 9)
        let items = try store.items()
        #expect(items.map(\.id) == [2, 1])
        #expect(items[0].title == "截图" && items[0].recognizedText == "发票" && items[0].pinnedToTopAt != nil)
        #expect(items[0].thumbnail == Data([0xFF, 0xD8]))
        #expect(try store.content(id: 2)?.image == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(items[1].preview == "hello" && items[1].sourceName == "备忘录" && items[1].pinboardIDs == [1])
        #expect(try store.items(matching: ClipQuery(pinboardID: 1)).map(\.id) == [2, 1])
        #expect(try store.items(matching: ClipQuery(text: "发票")).map(\.id) == [2])
        #expect(try store.items(matching: ClipQuery(sourceBundleID: "com.apple.Notes")).map(\.id) == [1])
        #expect(try store.insert(ClipContent(kind: .text, text: "new"), source: nil) == 8)

        let indexes = try old.prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'clips' AND sql IS NOT NULL ORDER BY name")
        var names: [String] = []
        while try indexes.step() { names.append(indexes.text(0) ?? "") }
        #expect(names == ["clips_created_at", "clips_pinned_top", "clips_source_bundle_id"])
        // pinboard_items 的外键仍然指向 clips（新表改名后的名字），不是已经删掉的旧表。
        let keys = try old.prepare("SELECT \"table\" FROM pragma_foreign_key_list('pinboard_items') ORDER BY \"table\"")
        var targets: [String] = []
        while try keys.step() { targets.append(keys.text(0) ?? "") }
        #expect(targets == ["clips", "pinboards"])
        // 旧表的页整理掉了，文件不会变成两倍大。
        let free = try old.prepare("PRAGMA freelist_count")
        _ = try free.step()
        #expect(free.int(0) == 0)
    }

    /// 第 8 版迁移中途失败（这里用一个同名的索引让建索引出错，真实情况是磁盘满了）时整个回滚，
    /// 问题解决后再打开能接着升级，不会因为列已经加过而再也打不开。
    @Test func versionEightMigrationCanBeRetriedAfterAFailure() throws {
        let dir = try ClipStoreTests.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("history.sqlite").path

        let old = try ClipStore(path: path)
        try old.insert(ClipContent(kind: .text, text: "first"), source: nil, at: Date(timeIntervalSince1970: 1))
        let raw = try SQLiteDatabase(path: path)
        try raw.execute("""
            DROP INDEX clips_pinned_top; ALTER TABLE clips DROP COLUMN pinned_top_at; PRAGMA user_version = 7;
            CREATE INDEX clips_pinned_top ON clips (created_at);
            """)
        func hasPinColumn() throws -> Bool {
            let statement = try raw.prepare("SELECT count(*) FROM pragma_table_info('clips') WHERE name = 'pinned_top_at'")
            _ = try statement.step()
            return statement.int(0) == 1
        }

        #expect(throws: (any Error).self) { try ClipStore(path: path) }
        #expect(try raw.userVersion == 7)
        #expect(try !hasPinColumn())

        try raw.execute("DROP INDEX clips_pinned_top;")
        let store = try ClipStore(path: path)
        #expect(try raw.userVersion == 9)
        #expect(try hasPinColumn())
        #expect(try store.items().map(\.preview) == ["first"])
    }
}
