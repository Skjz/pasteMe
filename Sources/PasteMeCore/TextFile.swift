import AppKit
import UniformTypeIdentifiers

/// 文本粘贴或拖到访达时生成的 .txt 文件（#36）。
public enum TextFile {
    /// 访达的 bundle id。粘贴的目标是它时，文本附带一个 .txt 文件。
    public static let finderBundleID = "com.apple.finder"

    /// 文件名，不带扩展名：有标题时用标题，否则用第一行的前 40 个字；都用不了时用复制时间，
    /// 例如 `PasteMe 2026-10-16 14.41.55`，和图片文件一样。
    /// `/` 和 `:` 不能出现在文件名里，换成空格；开头的 `.` 去掉，免得成了隐藏文件。
    public static func name(title: String?, text: String, copiedAt: Date) -> String {
        for candidate in [title, text.split(whereSeparator: \.isNewline).first.map(String.init)] {
            guard let candidate else { continue }
            let cleaned = String(candidate.map { $0 == "/" || $0 == ":" || $0.isNewline ? " " : $0 })
                .filter { !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
                .trimmingCharacters(in: .whitespaces)
                .drop { $0 == "." }
            let name = String(cleaned.prefix(40)).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return "PasteMe \(TemporaryFiles.timestamp(copiedAt))"
    }

    /// 文件内容：UTF-8，不带 BOM。
    public static func data(_ text: String) -> Data {
        Data(text.utf8)
    }
}

/// 拖出文本卡片时交给拖拽的内容（#36）：访达这类收文件的地方拿到一个 .txt 文件（file promise，
/// 放下时才写到目标文件夹），其他应用拿到文字和格式，和拖出普通文字一样。
public final class TextFilePromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    public let text: String
    public let rtf: Data?
    public let fileName: String

    /// `fileName` 不带扩展名，见 `TextFile.name`。
    public init(text: String, rtf: Data?, fileName: String) {
        self.text = text
        self.rtf = rtf
        self.fileName = fileName
        super.init()
        fileType = UTType.plainText.identifier
        delegate = self
    }

    override public func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + (rtf == nil ? [] : [.rtf]) + [.string]
    }

    override public func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .string: text
        case .rtf: rtf
        default: super.pasteboardPropertyList(forType: type)
        }
    }

    public func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        fileName + ".txt"
    }

    public func filePromiseProvider(
        _ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            try TextFile.data(text).write(to: url, options: .atomic)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}
