import Foundation

/// 右键卡片选「隔空投送…」时要发送的内容（#68）：链接发网址，文件发还在的原文件和文件夹，
/// 文本和图片先写成临时文件再发送。
public struct AirDropPlan: Equatable, Sendable {
    public enum Item: Equatable, Sendable {
        case url(URL)
        case temporaryFile(name: String, data: Data)
    }

    public var items: [Item]
    /// 文件条目里已经不在原处的文件个数。
    public var missing: Int
    /// 发送不了的原因，菜单里写在后面。可以发送时为 nil。
    public var unavailableReason: String?

    public init(items: [Item], missing: Int = 0, unavailableReason: String? = nil) {
        self.items = items
        self.missing = missing
        self.unavailableReason = unavailableReason
    }

    public static let defaultTextName = "PasteMe 文本"
    public static let defaultImageName = "PasteMe 图片"
    public static let maxFirstLineLength = 30

    /// 按条目的类型、内容、标题和文件在不在，算出要交给隔空投送的东西。
    public static func make(
        kind: ClipKind,
        text: String?,
        image: Data? = nil,
        title: String? = nil,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> AirDropPlan {
        switch kind {
        case .link:
            let address = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: address), url.scheme != nil else {
                return AirDropPlan(items: [], unavailableReason: "网址无效")
            }
            return AirDropPlan(items: [.url(url)])
        case .file:
            var items: [Item] = []
            var missing = 0
            for path in (text ?? "").split(separator: "\n").map(String.init) {
                if fileExists(path) {
                    items.append(.url(URL(fileURLWithPath: path)))
                } else {
                    missing += 1
                }
            }
            return AirDropPlan(
                items: items,
                missing: missing,
                unavailableReason: items.isEmpty ? "文件已经不在了" : nil
            )
        case .text:
            let body = text ?? ""
            let name = fileName(
                title: title,
                firstLineOf: body,
                fallback: defaultTextName,
                pathExtension: "txt"
            )
            return AirDropPlan(items: [.temporaryFile(name: name, data: TextFile.data(body))])
        case .image:
            guard let image, !image.isEmpty else {
                return AirDropPlan(items: [], unavailableReason: "图片不可用")
            }
            let name = fileName(
                title: title,
                firstLineOf: nil,
                fallback: defaultImageName,
                pathExtension: "png"
            )
            return AirDropPlan(items: [.temporaryFile(name: name, data: image)])
        }
    }

    /// 临时文件的文件名（带扩展名）：有标题时用标题，否则用文本第一行的前 30 个字，都为空时用 `fallback`。
    /// `/` 和 `:` 不能出现在文件名里，换成空格；开头的 `.` 去掉，免得成了隐藏文件。
    public static func fileName(
        title: String?,
        firstLineOf text: String?,
        fallback: String,
        pathExtension ext: String
    ) -> String {
        let firstLine = text?.split(whereSeparator: \.isNewline).first.map(String.init)
        let candidates: [(String?, Int)] = [(title, 80), (firstLine, maxFirstLineLength)]
        for (candidate, limit) in candidates {
            guard let candidate else { continue }
            let cleaned = String(candidate.map { $0 == "/" || $0 == ":" || $0.isNewline ? " " : $0 })
                .filter { !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
                .trimmingCharacters(in: .whitespaces)
                .drop { $0 == "." }
            let base = String(cleaned.prefix(limit)).trimmingCharacters(in: .whitespaces)
            if !base.isEmpty {
                let suffix = "." + ext
                if base.lowercased().hasSuffix(suffix.lowercased()), base.count > suffix.count {
                    return base
                }
                return base + suffix
            }
        }
        return "\(fallback).\(ext)"
    }
}

/// 隔空投送发送文本和图片时用的临时目录（#68）。
///
/// 和保留一天的 `TemporaryFiles` 不同，隔空投送有结束回调：每次发送建一个子目录，发送完成、失败或取消后立即删掉；
/// 应用启动时调用 `removeAll()` 清掉上次异常退出可能留下的文件。
public struct AirDropFiles: Sendable {
    public struct Prepared: Sendable {
        public let urls: [URL]
        private let sessionDirectory: URL?

        init(urls: [URL], sessionDirectory: URL?) {
            self.urls = urls
            self.sessionDirectory = sessionDirectory
        }

        public func cleanUp() {
            guard let sessionDirectory else { return }
            try? FileManager.default.removeItem(at: sessionDirectory)
        }
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Caches/PasteMe/AirDrop`，开发版是 `PasteMe Dev` 目录（`AppVariant`）。
    public static func defaultDirectory() throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return caches
            .appendingPathComponent(AppVariant.current.folderName, isDirectory: true)
            .appendingPathComponent("AirDrop", isDirectory: true)
    }

    /// 清空整个隔空投送临时目录，应用启动时调用。
    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 把计划里的临时文件写进独立的子目录，返回交给 `NSSharingService` 的所有 `URL` 和清理句柄。
    /// 只有链接或原文件时不建目录。
    public func prepare(_ items: [AirDropPlan.Item]) throws -> Prepared {
        let needsTemp = items.contains {
            if case .temporaryFile = $0 { return true }
            return false
        }
        let sessionDirectory: URL?
        if needsTemp {
            let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            sessionDirectory = folder
        } else {
            sessionDirectory = nil
        }

        do {
            let urls: [URL] = try items.map { item in
                switch item {
                case .url(let url):
                    return url
                case .temporaryFile(let name, let data):
                    let fileURL = sessionDirectory!.appendingPathComponent(name)
                    try data.write(to: fileURL, options: .atomic)
                    return fileURL
                }
            }
            return Prepared(urls: urls, sessionDirectory: sessionDirectory)
        } catch {
            if let sessionDirectory {
                try? FileManager.default.removeItem(at: sessionDirectory)
            }
            throw error
        }
    }
}
