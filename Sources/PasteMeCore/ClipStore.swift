import Foundation

/// 剪贴板历史的持久化存储（SQLite）。
///
/// 不是线程安全的类型，调用方应在同一个线程（应用里是主线程）上使用。
public final class ClipStore {
    /// 卡片预览最多读取的字符数，避免把超长文本整段读进内存。
    public static let previewLength = 2_000

    private let db: SQLiteDatabase

    /// `path` 传 `":memory:"` 得到一个只在内存里的库，测试用。
    public init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try db.execute("PRAGMA journal_mode = WAL")
        // Pinboard 删除时，固定在里面的记录（pinboard_items）跟着删除。
        try db.execute("PRAGMA foreign_keys = ON")
        try migrate()
    }

    /// `~/Library/Application Support/PasteMe/history.sqlite`
    public static func defaultPath() throws -> String {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("PasteMe", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.sqlite").path
    }

    private func migrate() throws {
        if try db.userVersion < 1 {
            try db.execute("""
                CREATE TABLE clips (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL,
                    text TEXT,
                    rtf BLOB,
                    image BLOB,
                    thumbnail BLOB,
                    source_bundle_id TEXT,
                    source_name TEXT,
                    content_hash TEXT NOT NULL UNIQUE,
                    created_at REAL NOT NULL
                );
                CREATE INDEX clips_created_at ON clips (created_at DESC);
                PRAGMA user_version = 1;
                """)
        }
        if try db.userVersion < 2 {
            // 按来源应用筛选，以及列出历史里出现过的应用（#4）。
            try db.execute("""
                CREATE INDEX clips_source_bundle_id ON clips (source_bundle_id);
                PRAGMA user_version = 2;
                """)
        }
        if try db.userVersion < 3 {
            // 图片里识别出的文字（#5）。NULL 表示还没识别，空字符串表示识别过但没有文字，以后不再识别。
            try db.execute("""
                ALTER TABLE clips ADD COLUMN ocr_text TEXT;
                PRAGMA user_version = 3;
                """)
        }
        if try db.userVersion < 4 {
            // 用户给条目起的标题（#10）。
            try db.execute("""
                ALTER TABLE clips ADD COLUMN title TEXT;
                PRAGMA user_version = 4;
                """)
        }
        if try db.userVersion < 5 {
            // 链接预览（#11）：网页标题和网站图标，预览图存在 thumbnail 里。
            // link_title 为 NULL 表示还没获取，空字符串表示获取过但没有拿到，以后不再获取。
            try db.execute("""
                ALTER TABLE clips ADD COLUMN link_title TEXT;
                ALTER TABLE clips ADD COLUMN link_icon BLOB;
                PRAGMA user_version = 5;
                """)
        }
        if try db.userVersion < 6 {
            // Pinboard（#9）。sort_order 越小越靠前。
            try db.execute("""
                CREATE TABLE pinboards (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    color TEXT NOT NULL,
                    sort_order INTEGER NOT NULL
                );
                CREATE TABLE pinboard_items (
                    pinboard_id INTEGER NOT NULL REFERENCES pinboards (id) ON DELETE CASCADE,
                    clip_id INTEGER NOT NULL REFERENCES clips (id) ON DELETE CASCADE,
                    sort_order INTEGER NOT NULL,
                    PRIMARY KEY (pinboard_id, clip_id)
                );
                CREATE INDEX pinboard_items_clip_id ON pinboard_items (clip_id);
                PRAGMA user_version = 6;
                """)
        }
        if try db.userVersion < 7 {
            // 文本子类型（#26、#28），只有文本条目有。NULL 表示还没识别，空字符串表示识别过、不是任何子类型。
            // 已有的文本条目由 `backfillTextSubtypes` 分批补算，不在这里算，免得历史很多时启动变慢。
            try db.execute("""
                ALTER TABLE clips ADD COLUMN text_subtype TEXT;
                PRAGMA user_version = 7;
                """)
        }
    }

    /// 在一个事务里执行，出错时回滚。
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try db.execute("BEGIN")
        do {
            let result = try body()
            try db.execute("COMMIT")
            return result
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    /// 保存一次复制。内容已存在时不新增，只把原记录的时间和来源更新为这一次，使其排到最前。
    /// 返回记录的 id。
    @discardableResult
    public func insert(_ content: ClipContent, source: ClipSource?, at date: Date = Date()) throws -> Int64 {
        let statement = try db.prepare(
            """
            INSERT INTO clips (
                kind, text, rtf, image, thumbnail, source_bundle_id, source_name, content_hash, created_at, text_subtype
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (content_hash) DO UPDATE SET
                thumbnail = coalesce(clips.thumbnail, excluded.thumbnail),
                created_at = excluded.created_at,
                source_bundle_id = excluded.source_bundle_id,
                source_name = excluded.source_name,
                -- 同一段代码从编辑器复制时认得出语言，从别处再复制一次时可能认不出，保留认出来的那次。
                text_subtype = coalesce(nullif(excluded.text_subtype, ''), clips.text_subtype, excluded.text_subtype)
            RETURNING id
            """,
            [
                .text(content.kind.rawValue),
                content.text.sqlValue,
                content.rtf.sqlValue,
                content.image.sqlValue,
                Self.thumbnail(for: content).sqlValue,
                source?.bundleID.sqlValue ?? .null,
                source?.name.sqlValue ?? .null,
                .text(content.contentHash),
                .double(date.timeIntervalSince1970),
                Self.textSubtypeValue(for: content, sourceBundleID: source?.bundleID),
            ]
        )
        guard try statement.step() else { throw SQLiteError(code: -1, message: "插入后没有返回 id") }
        return statement.int(0)
    }

    /// 返回符合 `query` 的条目：按时间倒序；按 Pinboard 查询时按条目在 Pinboard 里的顺序。
    public func items(matching query: ClipQuery = ClipQuery()) throws -> [ClipItem] {
        var sql = """
            SELECT clips.id, kind, substr(text, 1, \(Self.previewLength)), length(text), thumbnail,
                   source_bundle_id, source_name, created_at, substr(ocr_text, 1, \(Self.previewLength)),
                   title, link_title, link_icon,
                   (SELECT group_concat(pinboard_id) FROM pinboard_items WHERE clip_id = clips.id),
                   text_subtype
            """
        var values: [SQLValue] = []
        if let pinboardID = query.pinboardID {
            sql += ", pin.sort_order FROM clips JOIN pinboard_items AS pin ON pin.clip_id = clips.id AND pin.pinboard_id = ?"
            values.append(.int(pinboardID))
        } else {
            sql += ", NULL FROM clips"
        }
        if let filter = query.filter {
            sql += " WHERE " + filter.clause
            values += filter.values
        }
        sql += " ORDER BY " + (query.pinboardID == nil ? "" : "pin.sort_order, ") + "created_at DESC, clips.id DESC LIMIT ?"
        values.append(.int(Int64(query.limit)))

        let statement = try db.prepare(sql, values)
        var items: [ClipItem] = []
        while try statement.step() {
            guard let kind = statement.text(1).flatMap(ClipKind.init(rawValue:)) else { continue }
            let pins = statement.text(12)?.split(separator: ",").compactMap { Int64($0) } ?? []
            items.append(ClipItem(
                id: statement.int(0),
                kind: kind,
                preview: statement.text(2),
                textLength: Int(statement.int(3)),
                thumbnail: statement.blob(4),
                sourceBundleID: statement.text(5),
                sourceName: statement.text(6),
                createdAt: Date(timeIntervalSince1970: statement.double(7)),
                recognizedText: statement.text(8),
                title: statement.text(9),
                linkTitle: statement.text(10),
                linkIcon: statement.blob(11),
                pinboardIDs: Set(pins),
                pinOrder: statement.isNull(14) ? nil : statement.int(14),
                textSubtype: statement.text(13).flatMap(TextSubtype.init(rawValue:))
            ))
        }
        return items
    }

    /// 一个条目，不存在时为 nil。
    public func item(id: Int64) throws -> ClipItem? {
        try items(matching: ClipQuery(ids: [id], limit: 1)).first
    }

    /// 条目在历史里排第几（从 0 开始）：比它新的条目有多少条。不存在时为 nil。
    public func historyPosition(of id: Int64) throws -> Int? {
        let statement = try db.prepare(
            """
            SELECT count(*) FROM clips, (SELECT created_at AS t FROM clips WHERE id = ?) AS target
            WHERE created_at > target.t OR (created_at = target.t AND id > ?)
            """,
            [.int(id), .int(id)]
        )
        guard try item(id: id) != nil, try statement.step() else { return nil }
        return Int(statement.int(0))
    }

    /// 读取一条记录的完整内容，用于粘贴。
    public func content(id: Int64) throws -> ClipContent? {
        let statement = try db.prepare("SELECT kind, text, rtf, image FROM clips WHERE id = ?", [.int(id)])
        guard try statement.step(), let kind = statement.text(0).flatMap(ClipKind.init(rawValue:)) else {
            return nil
        }
        return ClipContent(kind: kind, text: statement.text(1), rtf: statement.blob(2), image: statement.blob(3))
    }

    /// 把记录移到最前面，例如从历史里粘贴之后。
    public func touch(id: Int64, at date: Date = Date()) throws {
        try db.run("UPDATE clips SET created_at = ? WHERE id = ?", [.double(date.timeIntervalSince1970), .int(id)])
    }

    /// 删除一条记录（也从所有 Pinboard 里去掉），返回删除前的完整数据，交给 `restore(_:)` 可以原样恢复。
    /// 记录不存在时返回 nil。
    @discardableResult
    public func delete(id: Int64) throws -> DeletedClip? {
        try transaction {
            let statement = try db.prepare("SELECT * FROM clips WHERE id = ?", [.int(id)])
            guard try statement.step() else { return nil }
            var row: [String: SQLValue] = [:]
            for column in 0..<statement.columnCount {
                row[statement.columnName(column)] = statement.value(column)
            }
            let pins = try pinPositions(of: id)
            try db.run("DELETE FROM pinboard_items WHERE clip_id = ?", [.int(id)])
            try db.run("DELETE FROM clips WHERE id = ?", [.int(id)])
            return DeletedClip(id: id, row: row, pins: pins)
        }
    }

    /// 撤销删除：用原来的 id、时间、缩略图和其他所有字段放回历史，也放回原来的 Pinboard 和位置
    /// （Pinboard 已经删掉的除外）。删除之后又复制过相同内容时，保留那条更新的记录，不把它挪回旧的位置。
    /// 返回恢复后条目的 id。
    @discardableResult
    public func restore(_ clip: DeletedClip) throws -> Int64 {
        try transaction {
            let columns = clip.row.keys.sorted()
            try db.run(
                """
                INSERT INTO clips (\(columns.map { "\"\($0)\"" }.joined(separator: ", ")))
                VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))
                ON CONFLICT DO NOTHING
                """,
                columns.map { clip.row[$0] ?? .null }
            )
            let statement = try db.prepare(
                "SELECT id FROM clips WHERE content_hash = ?",
                [clip.row["content_hash"] ?? .null]
            )
            guard try statement.step() else { throw SQLiteError(code: -1, message: "恢复后找不到条目") }
            let id = statement.int(0)
            for pin in clip.pins {
                try restorePin(UnpinnedClip(clipID: id, position: pin))
            }
            return id
        }
    }

    private func pinPositions(of id: Int64) throws -> [PinPosition] {
        let statement = try db.prepare(
            "SELECT pinboard_id, sort_order FROM pinboard_items WHERE clip_id = ?",
            [.int(id)]
        )
        var pins: [PinPosition] = []
        while try statement.step() {
            pins.append(PinPosition(pinboardID: statement.int(0), sortOrder: statement.int(1)))
        }
        return pins
    }

    // MARK: - 编辑

    /// 改条目的文字（#10），只能改文本和链接。`rtf` 是改后的富文本，链接没有富文本。
    ///
    /// 改完的内容和另一个条目相同时合并成一条：留下正在改的这条，复制时间取两条中较新的，
    /// 这条没有标题时用另一条的标题，另一条所在的 Pinboard 也加进来，然后删掉另一条。
    /// 链接改了网址后，原来的网页标题、图标和预览图都作废，可以重新获取。
    /// 返回 false 表示没有改：条目不存在、不是文本或链接，或者改后的文字是空的。
    @discardableResult
    public func updateText(_ text: String, rtf: Data?, id: Int64) throws -> Bool {
        guard let current = try content(id: id), current.kind == .text || current.kind == .link,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let edited = current.kind == .link && PasteboardCodec.isWebLink(trimmed)
            ? ClipContent(kind: .link, text: trimmed)
            : ClipContent(kind: .text, text: text, rtf: rtf)
        let hash = edited.contentHash
        try transaction {
            let other = try db.prepare(
                "SELECT id, created_at, title FROM clips WHERE content_hash = ? AND id != ?",
                [.text(hash), .int(id)]
            )
            if try other.step() {
                let otherID = other.int(0)
                try db.run(
                    """
                    UPDATE pinboard_items SET clip_id = ?
                    WHERE clip_id = ? AND pinboard_id NOT IN (SELECT pinboard_id FROM pinboard_items WHERE clip_id = ?)
                    """,
                    [.int(id), .int(otherID), .int(id)]
                )
                try db.run("DELETE FROM pinboard_items WHERE clip_id = ?", [.int(otherID)])
                try db.run("DELETE FROM clips WHERE id = ?", [.int(otherID)])
                try db.run(
                    "UPDATE clips SET created_at = max(created_at, ?), title = coalesce(title, ?) WHERE id = ?",
                    [.double(other.double(1)), other.text(2).sqlValue, .int(id)]
                )
            }
            let urlChanged = current.kind == .link && current.text != edited.text
            let source = try db.prepare("SELECT source_bundle_id FROM clips WHERE id = ?", [.int(id)])
            let sourceBundleID = try source.step() ? source.text(0) : nil
            try db.run(
                """
                UPDATE clips SET kind = ?, text = ?, rtf = ?, content_hash = ?, text_subtype = ?\(urlChanged
                    ? ", link_title = NULL, link_icon = NULL, thumbnail = NULL" : "")
                WHERE id = ?
                """,
                [
                    .text(edited.kind.rawValue), edited.text.sqlValue, edited.rtf.sqlValue, .text(hash),
                    Self.textSubtypeValue(for: edited, sourceBundleID: sourceBundleID), .int(id),
                ]
            )
        }
        return true
    }

    /// 给条目起标题。去掉首尾空白后为空时去掉标题。
    public func setTitle(_ title: String?, id: Int64) throws {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        try db.run(
            "UPDATE clips SET title = ? WHERE id = ?",
            [trimmed?.isEmpty == false ? .text(trimmed!) : .null, .int(id)]
        )
    }

    // MARK: - 图片中的文字

    /// 还没识别过文字的图片条目（图片，以及有缩略图的图片文件），新的在前。
    public func idsPendingTextRecognition() throws -> [Int64] {
        let statement = try db.prepare(
            """
            SELECT id FROM clips
            WHERE ocr_text IS NULL AND (kind = 'image' OR (kind = 'file' AND thumbnail IS NOT NULL))
            ORDER BY created_at DESC
            """
        )
        var ids: [Int64] = []
        while try statement.step() { ids.append(statement.int(0)) }
        return ids
    }

    /// 要识别文字的图片。条目不存在、不是图片或已经识别过时返回 nil。
    public func textRecognitionInput(id: Int64) throws -> TextRecognitionInput? {
        let statement = try db.prepare(
            "SELECT kind, image, text, thumbnail FROM clips WHERE id = ? AND ocr_text IS NULL",
            [.int(id)]
        )
        guard try statement.step() else { return nil }
        switch statement.text(0).flatMap(ClipKind.init(rawValue:)) {
        case .image:
            return statement.blob(1).map(TextRecognitionInput.imageData)
        case .file:
            // 只有图片文件有缩略图。识别原文件，原文件不在了再退而识别缩略图。
            guard let thumbnail = statement.blob(3),
                  let path = statement.text(2)?.split(separator: "\n").first
            else { return nil }
            return .imageFile(URL(fileURLWithPath: String(path)), fallback: thumbnail)
        case .text, .link, nil:
            return nil
        }
    }

    /// 保存识别结果。没有文字时传空字符串，这个条目以后不再识别。
    public func setRecognizedText(_ text: String, id: Int64) throws {
        try db.run("UPDATE clips SET ocr_text = ? WHERE id = ?", [.text(text), .int(id)])
    }

    /// 历史里出现过的来源应用，按条目数从多到少排列。没有 bundle id 的条目不算在内。
    public func sourceApps() throws -> [SourceApp] {
        // 应用名取这个应用最近一条条目上的名字（SQLite 里和 max() 一起查询的列取自那一行）。
        let statement = try db.prepare(
            """
            SELECT source_bundle_id, source_name, count(*), max(created_at)
            FROM clips
            WHERE source_bundle_id IS NOT NULL
            GROUP BY source_bundle_id
            ORDER BY count(*) DESC, max(created_at) DESC
            """
        )
        var apps: [SourceApp] = []
        while try statement.step() {
            guard let bundleID = statement.text(0) else { continue }
            apps.append(SourceApp(bundleID: bundleID, name: statement.text(1) ?? bundleID, count: Int(statement.int(2))))
        }
        return apps
    }

    // MARK: - 链接预览

    /// 还没获取过预览的链接条目的网址。条目不存在、不是链接或已经获取过时返回 nil。
    public func linkPreviewURL(id: Int64) throws -> URL? {
        let statement = try db.prepare(
            "SELECT text FROM clips WHERE id = ? AND kind = 'link' AND link_title IS NULL",
            [.int(id)]
        )
        guard try statement.step() else { return nil }
        return statement.text(0).flatMap(URL.init(string:))
    }

    /// 保存获取到的链接预览。获取失败时传 `LinkPreview.failed`，这个条目以后不再获取。
    public func setLinkPreview(_ preview: LinkPreview, id: Int64) throws {
        try db.run(
            "UPDATE clips SET link_title = ?, link_icon = ?, thumbnail = ? WHERE id = ? AND kind = 'link'",
            [.text(preview.title), preview.icon.sqlValue, preview.image.sqlValue, .int(id)]
        )
    }

    // MARK: - Pinboard

    /// 所有 Pinboard，按标签的顺序排列。
    public func pinboards() throws -> [Pinboard] {
        let statement = try db.prepare("SELECT id, name, color FROM pinboards ORDER BY sort_order, id")
        var pinboards: [Pinboard] = []
        while try statement.step() {
            pinboards.append(Pinboard(
                id: statement.int(0),
                name: statement.text(1) ?? "",
                color: statement.text(2).flatMap(PinboardColor.init(rawValue:)) ?? .gray
            ))
        }
        return pinboards
    }

    /// 新建一个 Pinboard，排在最后。
    @discardableResult
    public func createPinboard(name: String, color: PinboardColor) throws -> Pinboard {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let statement = try db.prepare(
            """
            INSERT INTO pinboards (name, color, sort_order)
            VALUES (?, ?, (SELECT coalesce(max(sort_order), 0) + 1 FROM pinboards))
            RETURNING id
            """,
            [.text(name), .text(color.rawValue)]
        )
        guard try statement.step() else { throw SQLiteError(code: -1, message: "新建 Pinboard 后没有返回 id") }
        return Pinboard(id: statement.int(0), name: name, color: color)
    }

    public func renamePinboard(_ id: Int64, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        try db.run("UPDATE pinboards SET name = ? WHERE id = ?", [.text(name), .int(id)])
    }

    public func setColor(_ color: PinboardColor, ofPinboard id: Int64) throws {
        try db.run("UPDATE pinboards SET color = ? WHERE id = ?", [.text(color.rawValue), .int(id)])
    }

    /// 删除一个 Pinboard。里面的条目还在历史里，只是不再固定在这里。
    public func deletePinboard(_ id: Int64) throws {
        try transaction {
            try db.run("DELETE FROM pinboard_items WHERE pinboard_id = ?", [.int(id)])
            try db.run("DELETE FROM pinboards WHERE id = ?", [.int(id)])
        }
    }

    /// 把条目固定到 Pinboard 的最前面。已经在里面时不动它的位置，返回 false。
    @discardableResult
    public func pin(_ clipID: Int64, to pinboardID: Int64) throws -> Bool {
        let statement = try db.prepare(
            """
            INSERT INTO pinboard_items (pinboard_id, clip_id, sort_order)
            SELECT ?, ?, coalesce(min(sort_order), 1) - 1 FROM pinboard_items WHERE pinboard_id = ?
            ON CONFLICT DO NOTHING
            RETURNING clip_id
            """,
            [.int(pinboardID), .int(clipID), .int(pinboardID)]
        )
        guard try statement.step() else { return false }
        while try statement.step() {}
        return true
    }

    /// 把条目从 Pinboard 里拿掉，条目还在历史里。返回原来的位置，交给 `restorePin(_:)` 可以放回去。
    @discardableResult
    public func unpin(_ clipID: Int64, from pinboardID: Int64) throws -> UnpinnedClip? {
        let statement = try db.prepare(
            "DELETE FROM pinboard_items WHERE pinboard_id = ? AND clip_id = ? RETURNING sort_order",
            [.int(pinboardID), .int(clipID)]
        )
        guard try statement.step() else { return nil }
        let removed = UnpinnedClip(clipID: clipID, position: PinPosition(pinboardID: pinboardID, sortOrder: statement.int(0)))
        while try statement.step() {}
        return removed
    }

    /// 撤销 `unpin`：放回原来的位置。Pinboard 或条目已经不在时什么也不做。
    public func restorePin(_ pin: UnpinnedClip) throws {
        try db.run(
            """
            INSERT INTO pinboard_items (pinboard_id, clip_id, sort_order)
            SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM pinboards WHERE id = ?) AND EXISTS (SELECT 1 FROM clips WHERE id = ?)
            ON CONFLICT DO NOTHING
            """,
            [.int(pin.position.pinboardID), .int(pin.clipID), .int(pin.position.sortOrder),
             .int(pin.position.pinboardID), .int(pin.clipID)]
        )
    }

    /// 按 `clipIDs` 的顺序重排 Pinboard 里的条目。不在列表里的条目排到后面，相对顺序不变。
    public func setOrder(_ clipIDs: [Int64], inPinboard pinboardID: Int64) throws {
        try transaction {
            try db.run(
                "UPDATE pinboard_items SET sort_order = sort_order + ? WHERE pinboard_id = ?",
                [.int(Int64(clipIDs.count) + 1_000_000), .int(pinboardID)]
            )
            for (index, id) in clipIDs.enumerated() {
                try db.run(
                    "UPDATE pinboard_items SET sort_order = ? WHERE pinboard_id = ? AND clip_id = ?",
                    [.int(Int64(index)), .int(pinboardID), .int(id)]
                )
            }
        }
    }

    /// 固定在至少一个 Pinboard 里的条目数。
    public func pinnedCount() throws -> Int {
        let statement = try db.prepare("SELECT count(DISTINCT clip_id) FROM pinboard_items")
        _ = try statement.step()
        return Int(statement.int(0))
    }

    // MARK: - 清空

    /// 清空历史：删除不在任何 Pinboard 里的条目。固定在 Pinboard 里的条目和 Pinboard 本身都保留。
    public func clearHistory() throws {
        try db.run("DELETE FROM clips WHERE id NOT IN (SELECT clip_id FROM pinboard_items)")
        try db.execute("VACUUM")
    }

    public func count() throws -> Int {
        let statement = try db.prepare("SELECT count(*) FROM clips")
        _ = try statement.step()
        return Int(statement.int(0))
    }

    // MARK: - 文本子类型

    /// 给还没识别过子类型的文本条目补算（升级到第 7 版以前记下的），新的在前，一次最多 `limit` 条。
    /// 返回这次补算了几条，0 表示都算完了。
    @discardableResult
    public func backfillTextSubtypes(limit: Int = 500) throws -> Int {
        let statement = try db.prepare(
            """
            SELECT id, text, source_bundle_id FROM clips
            WHERE kind = 'text' AND text_subtype IS NULL ORDER BY created_at DESC LIMIT ?
            """,
            [.int(Int64(limit))]
        )
        var results: [(Int64, SQLValue)] = []
        while try statement.step() {
            let content = ClipContent(kind: .text, text: statement.text(1))
            results.append((statement.int(0), Self.textSubtypeValue(for: content, sourceBundleID: statement.text(2))))
        }
        try transaction {
            for (id, value) in results {
                try db.run("UPDATE clips SET text_subtype = ? WHERE id = ?", [value, .int(id)])
            }
        }
        return results.count
    }

    /// 存进 `text_subtype` 的值：文本是子类型的写法，不是任何子类型时为空字符串；其他类型为 NULL。
    static func textSubtypeValue(for content: ClipContent, sourceBundleID: String?) -> SQLValue {
        guard content.kind == .text else { return .null }
        return .text(content.text.flatMap { TextSubtype.detect($0, sourceBundleID: sourceBundleID) }?.rawValue ?? "")
    }

    /// 图片取自身数据；文件取第一个文件（是图片时）。缩略图在复制时生成并入库，
    /// 原文件之后被移动或删除，卡片上仍能看到预览。
    static func thumbnail(for content: ClipContent) -> Data? {
        switch content.kind {
        case .image: content.image.flatMap { Thumbnailer.thumbnail(for: $0) }
        case .file: content.fileURLs.first.flatMap { Thumbnailer.thumbnail(forFileAt: $0) }
        case .text, .link: nil
        }
    }
}
