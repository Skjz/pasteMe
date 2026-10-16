import AppKit

/// 粘贴的方式。
public enum PasteMode: Sendable {
    /// 原样粘贴，保留富文本格式。
    case original
    /// 纯文本粘贴：去掉格式，只粘贴文字。
    case plainText
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
    func write(_ content: ClipContent)
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

    public func write(_ content: ClipContent) {
        PasteboardCodec.write(content, to: .general)
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

    public init(store: ClipStore, pasteboard: any PasteboardWriting, keystroke: any PasteKeystrokeSending) {
        self.store = store
        self.pasteboard = pasteboard
        self.keystroke = keystroke
    }

    public func paste(_ id: Int64, as mode: PasteMode = .original, into target: TargetApp?) throws -> PasteOutcome {
        guard var content = try store.content(id: id) else { throw PasteError.clipNotFound(id: id) }
        if mode == .plainText { content = content.plainTextOnly }

        pasteboard.write(content)
        // 内容已经在剪贴板里，排序没更新不影响这次粘贴。
        try? store.touch(id: id)

        // 没有权限时内容已经在剪贴板里，用户可以自己按 ⌘V。
        guard keystroke.isTrusted else { return .copiedOnly }
        keystroke.sendPaste(to: target)
        return .pasted
    }
}
