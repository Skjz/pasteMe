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
                   source_bundle_id, source_name, created_at
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

    /// 删除一条记录，返回删除前的完整数据，交给 `restore(_:)` 可以原样恢复。记录不存在时返回 nil。
    @discardableResult
    public func delete(id: Int64) throws -> DeletedClip? {
        let statement = try db.prepare(
            """
            DELETE FROM clips WHERE id = ?
            RETURNING kind, text, rtf, image, thumbnail, source_bundle_id, source_name, content_hash, created_at
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
            createdAt: statement.double(8)
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
            INSERT INTO clips (id, kind, text, rtf, image, thumbnail, source_bundle_id, source_name, content_hash, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            ]
        )
        let statement = try db.prepare("SELECT id FROM clips WHERE content_hash = ?", [.text(clip.contentHash)])
        guard try statement.step() else { throw SQLiteError(code: -1, message: "恢复后找不到条目") }
        return statement.int(0)
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
