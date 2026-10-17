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
    /// 从图片里识别出的文字（前若干字符）。nil 表示还没识别，空字符串表示识别过但没有文字。
    public var recognizedText: String?
    /// 用户给条目起的标题。没有起时为 nil。
    public var title: String?
    /// 链接的网页标题。nil 表示还没获取，空字符串表示获取过但没有拿到。
    public var linkTitle: String?
    /// 链接所在网站的图标（PNG）。
    public var linkIcon: Data?
    /// 条目固定在哪些 Pinboard 里。
    public var pinboardIDs: Set<Int64>
    /// 在 Pinboard 里的位置，只有按 Pinboard 查询（`ClipQuery.pinboardID`）时才有，越小越靠前。
    public var pinOrder: Int64?

    public init(
        id: Int64,
        kind: ClipKind,
        preview: String?,
        textLength: Int,
        thumbnail: Data?,
        sourceBundleID: String?,
        sourceName: String?,
        createdAt: Date,
        recognizedText: String? = nil,
        title: String? = nil,
        linkTitle: String? = nil,
        linkIcon: Data? = nil,
        pinboardIDs: Set<Int64> = [],
        pinOrder: Int64? = nil
    ) {
        self.id = id
        self.kind = kind
        self.preview = preview
        self.textLength = textLength
        self.thumbnail = thumbnail
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.createdAt = createdAt
        self.recognizedText = recognizedText
        self.title = title
        self.linkTitle = linkTitle
        self.linkIcon = linkIcon
        self.pinboardIDs = pinboardIDs
        self.pinOrder = pinOrder
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

/// 历史里出现过的一个来源应用，以及来自它的条目数。
public struct SourceApp: Sendable, Equatable, Identifiable {
    public var bundleID: String
    public var name: String
    public var count: Int

    public var id: String { bundleID }

    public init(bundleID: String, name: String, count: Int) {
        self.bundleID = bundleID
        self.name = name
        self.count = count
    }
}

/// 被删除条目的完整数据，由 `ClipStore.delete(id:)` 返回，用于撤销删除。
public struct DeletedClip: Sendable, Equatable {
    public let id: Int64
    /// 删除前的整行，按列名保存。以后给表加列时这里不用改。
    let row: [String: SQLValue]
    /// 删除前固定在哪些 Pinboard 里、排在什么位置。
    let pins: [PinPosition]
}

/// 条目在一个 Pinboard 里的位置。
public struct PinPosition: Sendable, Equatable {
    public var pinboardID: Int64
    public var sortOrder: Int64
}

/// 从 Pinboard 里移除的条目，由 `ClipStore.unpin(_:from:)` 返回，用于撤销。
public struct UnpinnedClip: Sendable, Equatable {
    public let clipID: Int64
    public let position: PinPosition
}

/// 用户自建、有名字的条目分组。固定在里面的条目清空历史时也会保留。
public struct Pinboard: Identifiable, Sendable, Equatable {
    public let id: Int64
    public var name: String
    public var color: PinboardColor

    public init(id: Int64, name: String, color: PinboardColor) {
        self.id = id
        self.name = name
        self.color = color
    }
}

/// Pinboard 的颜色，标签和卡片上的小圆点用它。存的是名字，界面决定具体的颜色值。
public enum PinboardColor: String, CaseIterable, Sendable {
    case red, orange, yellow, green, teal, blue, purple, pink, gray

    /// 新建 Pinboard 时依次使用的颜色，第 n 个 Pinboard 用第 n 种。
    public static func next(after existing: [Pinboard]) -> PinboardColor {
        let palette = allCases.filter { $0 != .gray }
        return palette[existing.count % palette.count]
    }
}
