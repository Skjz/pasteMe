import Foundation

/// 以文件粘贴或拖出图片时生成的 PNG 文件（#12），以及把文本粘贴到访达时生成的 .txt 文件（#36）。
///
/// 放在 `~/Library/Caches/PasteMe/Files/` 下，每个条目一个子目录，文件名用复制时间，
/// 例如 `PasteMe 2026-10-16 14.41.55.png`：同一秒复制的两张图片不会互相覆盖，访达里看到的文件名也好认。
/// 超过一天没用过的文件由 `removeExpired` 删除，缓存目录不会一直变大。
public struct TemporaryFiles: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Caches/PasteMe/Files`，开发版是 `PasteMe Dev` 目录（`AppVariant`）。
    public static func defaultDirectory() throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return caches
            .appendingPathComponent(AppVariant.current.folderName, isDirectory: true)
            .appendingPathComponent("Files", isDirectory: true)
    }

    /// 把条目的图片存成 PNG 文件，返回文件的地址。文件已经存在时不重写，只更新修改时间，从现在起再保留一天。
    public func imageFile(_ png: Data, id: Int64, copiedAt: Date) throws -> URL {
        let folder = directory.appendingPathComponent(String(id), isDirectory: true)
        let url = folder.appendingPathComponent("PasteMe \(Self.timestamp(copiedAt)).png")
        let manager = FileManager.default
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size == png.count {
            try manager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return url
        }
        // 同一条目以前存过、复制时间变了（又复制了一次）的旧文件一起换掉。
        try? manager.removeItem(at: folder)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: url, options: .atomic)
        return url
    }

    /// 把文本存成 .txt 文件（#36），返回文件的地址。`name` 不带扩展名，见 `TextFile.name`。
    /// 内容和文件名都没变时不重写，只更新修改时间，从现在起再保留一天。
    public func textFile(_ text: String, name: String, id: Int64) throws -> URL {
        let folder = directory.appendingPathComponent(String(id), isDirectory: true)
        let url = folder.appendingPathComponent(name + ".txt")
        let data = TextFile.data(text)
        let manager = FileManager.default
        if (try? Data(contentsOf: url)) == data {
            try manager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return url
        }
        // 改过文字或标题后，以前存的旧文件一起换掉。
        try? manager.removeItem(at: folder)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 删除超过 `maxAge` 秒没有用过的文件。
    public func removeExpired(maxAge: TimeInterval = 24 * 60 * 60, now: Date = Date()) {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let lastUsed = files.compactMap {
                try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }.max()
            if lastUsed.map({ now.timeIntervalSince($0) > maxAge }) ?? true {
                try? manager.removeItem(at: folder)
            }
        }
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }
}
