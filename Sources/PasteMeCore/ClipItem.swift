import CryptoKit
import Foundation

/// 一条剪贴板记录的类型。决定卡片怎么展示、粘贴时写回哪些 pasteboard 类型。
public enum ClipKind: String, Sendable, CaseIterable {
    case text
    case link
    case image
    case file
}

/// 一次复制得到的完整内容，用于入库和粘贴回去。
///
/// - `text`：纯文本；链接为 URL 字符串；文件为以换行分隔的文件路径。
/// - `rtf`：复制源提供的富文本，粘贴时一并写回以保留格式。
/// - `image`：PNG 数据。
public struct ClipContent: Sendable, Equatable {
    public var kind: ClipKind
    public var text: String?
    public var rtf: Data?
    public var image: Data?

    public init(kind: ClipKind, text: String? = nil, rtf: Data? = nil, image: Data? = nil) {
        self.kind = kind
        self.text = text
        self.rtf = rtf
        self.image = image
    }

    public var fileURLs: [URL] {
        guard kind == .file, let text else { return [] }
        return text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    /// 去掉格式，只保留纯文本。图片和文件原样返回。
    public var plainTextOnly: ClipContent {
        var copy = self
        copy.rtf = nil
        return copy
    }

    /// 用于去重：内容相同的两次复制只保留一条，并把它移到最前面。
    /// 富文本不参与计算，同一段文字带不同格式视为同一条。
    public var contentHash: String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        hasher.update(data: Data([0]))
        if let text { hasher.update(data: Data(text.utf8)) }
        hasher.update(data: Data([0]))
        if let image { hasher.update(data: image) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 历史列表里的一条记录。只带展示需要的字段，完整内容通过 `ClipStore.content(id:)` 按需读取。
public struct ClipItem: Identifiable, Sendable, Equatable {
    public let id: Int64
    public var kind: ClipKind
    /// 文本的前若干字符，用于卡片预览和搜索结果展示。
    public var preview: String?
    /// 完整文本的字符数。
    public var textLength: Int
    public var thumbnail: Data?
    public var sourceBundleID: String?
    public var sourceName: String?
    public var createdAt: Date

    public init(
        id: Int64,
        kind: ClipKind,
        preview: String?,
        textLength: Int,
        thumbnail: Data?,
        sourceBundleID: String?,
        sourceName: String?,
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.preview = preview
        self.textLength = textLength
        self.thumbnail = thumbnail
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.createdAt = createdAt
    }

    public var filePaths: [String] {
        guard kind == .file, let preview else { return [] }
        return preview.split(separator: "\n").map(String.init)
    }
}

/// 复制发生时的前台应用。
public struct ClipSource: Sendable, Equatable {
    public var bundleID: String?
    public var name: String?

    public init(bundleID: String?, name: String?) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// 被删除条目的完整数据，由 `ClipStore.delete(id:)` 返回，用于撤销删除。
public struct DeletedClip: Sendable, Equatable {
    public let id: Int64
    let kind: String
    let text: String?
    let rtf: Data?
    let image: Data?
    let thumbnail: Data?
    let sourceBundleID: String?
    let sourceName: String?
    let contentHash: String
    let createdAt: Double
}
