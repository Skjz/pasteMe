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
    }

    /// 保存一次复制。内容已存在时不新增，只把原记录的时间和来源更新为这一次，使其排到最前。
    /// 返回记录的 id。
    @discardableResult
    public func insert(_ content: ClipContent, source: ClipSource?, at date: Date = Date()) throws -> Int64 {
        let thumbnail = content.image.flatMap { Thumbnailer.thumbnail(for: $0) }
        let statement = try db.prepare(
            """
            INSERT INTO clips (kind, text, rtf, image, thumbnail, source_bundle_id, source_name, content_hash, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (content_hash) DO UPDATE SET
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
                thumbnail.sqlValue,
                source?.bundleID.sqlValue ?? .null,
                source?.name.sqlValue ?? .null,
                .text(content.contentHash),
                .double(date.timeIntervalSince1970),
            ]
        )
        guard try statement.step() else { throw SQLiteError(code: -1, message: "插入后没有返回 id") }
        return statement.int(0)
    }

    /// 按时间倒序返回最近的记录。`query` 非空时只返回文本或来源应用名包含该字符串的记录（不区分 ASCII 大小写）。
    public func recent(limit: Int = 200, matching query: String = "") throws -> [ClipItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var sql = """
            SELECT id, kind, substr(text, 1, \(Self.previewLength)), length(text), thumbnail,
                   source_bundle_id, source_name, created_at
            FROM clips
            """
        var values: [SQLValue] = []
        if !trimmed.isEmpty {
            sql += " WHERE text LIKE ? ESCAPE '\\' OR source_name LIKE ? ESCAPE '\\'"
            let pattern = "%" + Self.escapeLike(trimmed) + "%"
            values += [.text(pattern), .text(pattern)]
        }
        sql += " ORDER BY created_at DESC, id DESC LIMIT ?"
        values.append(.int(Int64(limit)))

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
                createdAt: Date(timeIntervalSince1970: statement.double(7))
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

    public func delete(id: Int64) throws {
        try db.run("DELETE FROM clips WHERE id = ?", [.int(id)])
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

    static func escapeLike(_ string: String) -> String {
        var escaped = ""
        for char in string {
            if char == "\\" || char == "%" || char == "_" { escaped.append("\\") }
            escaped.append(char)
        }
        return escaped
    }
}
