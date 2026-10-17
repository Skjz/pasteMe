import AppKit

/// 粘贴的方式。
public enum PasteMode: Sendable {
    /// 原样粘贴，保留富文本格式。
    case original
    /// 纯文本粘贴：去掉格式，只粘贴文字。
    case plainText
    /// 以文件粘贴：图片同时附带一个 PNG 文件（`TemporaryFiles`），访达、网页上传框这类只收文件的地方也能粘贴。
    /// 其他类型和 `.original` 一样。
    case file
}

/// 一次粘贴的结果。
public enum PasteOutcome: Sendable, Equatable {
    /// 内容已写入剪贴板，并向目标应用发送了 ⌘V。
    case pasted
    /// 没有辅助功能权限，只把内容放回了剪贴板，用户需要自己按 ⌘V。
    case copiedOnly
}

public enum PasteError: Error, Equatable {
    /// 要粘贴的条目已经不在历史里。
    case clipNotFound(id: Int64)
    /// 文件条目里的文件都已经不在原来的地方了。
    case filesMissing
}

/// 呼出面板时位于前台、接收粘贴的应用。
public struct TargetApp: Sendable, Equatable {
    public var bundleID: String?
    public var name: String?

    public init(bundleID: String?, name: String?) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// 把内容写到系统剪贴板。
@MainActor
public protocol PasteboardWriting {
    /// `file` 是图片另存成的 PNG 文件，以文件粘贴时才有。
    func write(_ content: ClipContent, attachingFile file: URL?)
}

/// 向目标应用发送 ⌘V。
@MainActor
public protocol PasteKeystrokeSending {
    /// 是否有辅助功能权限。没有权限时系统不接受合成按键。
    var isTrusted: Bool { get }
    func sendPaste(to target: TargetApp?)
}

/// 用 `PasteboardCodec` 写入 `NSPasteboard.general`。
public struct GeneralPasteboard: PasteboardWriting {
    public init() {}

    public func write(_ content: ClipContent, attachingFile file: URL?) {
        PasteboardCodec.write(content, attachingFile: file, to: .general)
    }
}

/// 粘贴条目：读取完整内容、按方式变换、写剪贴板、把条目移到历史最前、向目标应用发送 ⌘V。
///
/// 收起面板由调用方负责，应在调用 `paste` 之前完成，这样 ⌘V 才会落到目标应用上。
@MainActor
public final class Paster {
    private let store: ClipStore
    private let pasteboard: any PasteboardWriting
    private let keystroke: any PasteKeystrokeSending
    private let files: TemporaryFiles?
    /// 为 true 时，原样粘贴图片也附带 PNG 文件，和 `.file` 一样（设置里的「图片以文件粘贴」）。
    private let imagesAsFiles: () -> Bool

    /// - Parameter files: 以文件粘贴、拖出图片时，图片存到这里。为 nil 时只给图片数据。
    public init(
        store: ClipStore,
        pasteboard: any PasteboardWriting,
        keystroke: any PasteKeystrokeSending,
        files: TemporaryFiles? = nil,
        imagesAsFiles: @escaping () -> Bool = { false }
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.keystroke = keystroke
        self.files = files
        self.imagesAsFiles = imagesAsFiles
    }

    public func paste(_ id: Int64, as mode: PasteMode = .original, into target: TargetApp?) throws -> PasteOutcome {
        try copyToPasteboard(id, as: mode)

        // 没有权限时内容已经在剪贴板里，用户可以自己按 ⌘V。
        guard keystroke.isTrusted else { return .copiedOnly }
        keystroke.sendPaste(to: target)
        return .pasted
    }

    /// 只把条目写进剪贴板并移到历史最前，不发送 ⌘V。Paste Stack 用它：⌘V 是用户自己按的。
    public func copyToPasteboard(_ id: Int64, as mode: PasteMode = .original) throws {
        guard var content = try store.content(id: id) else { throw PasteError.clipNotFound(id: id) }
        if mode == .plainText { content = content.plainTextOnly }
        let attachesFile = mode == .file || (mode == .original && imagesAsFiles())

        pasteboard.write(content, attachingFile: attachesFile ? imageFile(for: content, id: id) : nil)
        // 内容已经在剪贴板里，排序没更新不影响这次粘贴。
        try? store.touch(id: id)
    }

    /// 从面板上拖出条目时交给拖拽的内容（#12）：和粘贴时写进剪贴板的一样，图片总是附带 PNG 文件。
    /// 文件条目只给还在的文件，一个都不在时抛出 `PasteError.filesMissing`。
    public func draggingWriters(for id: Int64) throws -> [NSPasteboardWriting] {
        guard var content = try store.content(id: id) else { throw PasteError.clipNotFound(id: id) }
        if content.kind == .file {
            let existing = content.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !existing.isEmpty else { throw PasteError.filesMissing }
            content.text = existing.map(\.path).joined(separator: "\n")
        }
        return PasteboardCodec.writers(for: content, attachingFile: imageFile(for: content, id: id))
    }

    /// 图片存成的 PNG 文件。不是图片、没有设置 `files` 或写文件失败时为 nil，这时只给图片数据。
    private func imageFile(for content: ClipContent, id: Int64) -> URL? {
        guard content.kind == .image, let png = content.image, let files else { return nil }
        do {
            let copiedAt = try store.item(id: id)?.createdAt ?? Date()
            return try files.imageFile(png, id: id, copiedAt: copiedAt)
        } catch {
            NSLog("PasteMe: 保存图片文件失败：\(error)")
            return nil
        }
    }
}
