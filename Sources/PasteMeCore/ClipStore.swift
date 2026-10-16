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
    }

    /// 保存一次复制。内容已存在时不新增，只把原记录的时间和来源更新为这一次，使其排到最前。
    /// 返回记录的 id。
    @discardableResult
    public func insert(_ content: ClipContent, source: ClipSource?, at date: Date = Date()) throws -> Int64 {
        let statement = try db.prepare(
            """
            INSERT INTO clips (kind, text, rtf, image, thumbnail, source_bundle_id, source_name, content_hash, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (content_hash) DO UPDATE SET
                thumbnail = coalesce(clips.thumbnail, excluded.thumbnail),
                created_at = excluded.created_at,
                source_bundle_id = excluded.source_bundle_id,
                source_name = excluded.source_name
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
            ]
        )
        guard try statement.step() else { throw SQLiteError(code: -1, message: "插入后没有返回 id") }
        return statement.int(0)
    }

    /// 按时间倒序返回符合 `query` 的条目。
    public func items(matching query: ClipQuery = ClipQuery()) throws -> [ClipItem] {
        var sql = """
            SELECT id, kind, substr(text, 1, \(Self.previewLength)), length(text), thumbnail,
                   source_bundle_id, source_name, created_at, substr(ocr_text, 1, \(Self.previewLength))
            FROM clips
            """
        var values: [SQLValue] = []
        if let filter = query.filter {
            sql += " WHERE " + filter.clause
            values += filter.values
        }
        sql += " ORDER BY created_at DESC, id DESC LIMIT ?"
        values.append(.int(Int64(query.limit)))

        let statement = try db.prepare(sql, values)
        var items: [ClipItem] = []
        while try statement.step() {
            guard let kind = statement.text(1).flatMap(ClipKind.init(rawValue:)) else { continue }
            items.append(ClipItem(
                id: statement.int(0),
                kind: kind,
                preview: statement.text(2),
                textLength: Int(statement.int(3)),
                thumbnail: statement.blob(4),
                sourceBundleID: statement.text(5),
                sourceName: statement.text(6),
                createdAt: Date(timeIntervalSince1970: statement.double(7)),
                recognizedText: statement.text(8)
            ))
        }
        return items
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

    /// 删除一条记录，返回删除前的完整数据，交给 `restore(_:)` 可以原样恢复。记录不存在时返回 nil。
    @discardableResult
    public func delete(id: Int64) throws -> DeletedClip? {
        let statement = try db.prepare(
            """
            DELETE FROM clips WHERE id = ?
            RETURNING kind, text, rtf, image, thumbnail, source_bundle_id, source_name, content_hash, created_at, ocr_text
            """,
            [.int(id)]
        )
        guard try statement.step() else { return nil }
        let deleted = DeletedClip(
            id: id,
            kind: statement.text(0) ?? "",
            text: statement.text(1),
            rtf: statement.blob(2),
            image: statement.blob(3),
            thumbnail: statement.blob(4),
            sourceBundleID: statement.text(5),
            sourceName: statement.text(6),
            contentHash: statement.text(7) ?? "",
            createdAt: statement.double(8),
            recognizedText: statement.text(9)
        )
        while try statement.step() {}
        return deleted
    }

    /// 撤销删除：用原来的 id、时间和缩略图放回历史。
    /// 删除之后又复制过相同内容时，保留那条更新的记录，不把它挪回旧的位置。返回恢复后条目的 id。
    @discardableResult
    public func restore(_ clip: DeletedClip) throws -> Int64 {
        try db.run(
            """
            INSERT INTO clips (id, kind, text, rtf, image, thumbnail, source_bundle_id, source_name, content_hash, created_at, ocr_text)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT DO NOTHING
            """,
            [
                .int(clip.id),
                .text(clip.kind),
                clip.text.sqlValue,
                clip.rtf.sqlValue,
                clip.image.sqlValue,
                clip.thumbnail.sqlValue,
                clip.sourceBundleID.sqlValue,
                clip.sourceName.sqlValue,
                .text(clip.contentHash),
                .double(clip.createdAt),
                clip.recognizedText.sqlValue,
            ]
        )
        let statement = try db.prepare("SELECT id FROM clips WHERE content_hash = ?", [.text(clip.contentHash)])
        guard try statement.step() else { throw SQLiteError(code: -1, message: "恢复后找不到条目") }
        return statement.int(0)
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

    public func deleteAll() throws {
        try db.run("DELETE FROM clips")
        try db.execute("VACUUM")
    }

    public func count() throws -> Int {
        let statement = try db.prepare("SELECT count(*) FROM clips")
        _ = try statement.step()
        return Int(statement.int(0))
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
