import AppKit
import Observation
import PasteMeCore
import Quartz
import SwiftUI

/// 预览窗口正在显示的内容和没保存的修改（#10）。
@Observable
@MainActor
final class PreviewState {
    /// 预览的条目。⌘N 新建文本时为 nil。
    private(set) var item: ClipItem?
    private(set) var content: ClipContent?
    /// 标题输入框里的文字。
    var title = ""
    @ObservationIgnored private(set) var originalTitle = ""
    /// 正文改过了。正文本身在 `textView` 里，关闭时才读出来。
    @ObservationIgnored var bodyEdited = false
    /// 每换一次内容加一，正文编辑器据此重新载入文字。
    private(set) var revision = 0
    /// 加一时标题输入框取得键盘焦点。
    private(set) var titleFocusRequest = 0
    /// 图片的缩放：加一时执行 `zoomCommand`。
    private(set) var zoomRevision = 0
    private(set) var zoomCommand = ZoomCommand.fit
    @ObservationIgnored weak var textView: NSTextView?

    enum ZoomCommand { case fit, actualSize, zoomIn, zoomOut }

    var isNewText: Bool { item == nil }
    /// 文本、链接和新建的文本可以改正文。
    var bodyIsEditable: Bool { item.map { $0.kind == .text || $0.kind == .link } ?? true }
    /// 正文按富文本编辑：复制时带着格式的文本。
    var isRichText: Bool { content?.rtf != nil && item?.kind == .text }

    func load(_ item: ClipItem?, content: ClipContent?) {
        self.item = item
        self.content = content
        title = item?.title ?? ""
        originalTitle = title
        bodyEdited = false
        revision += 1
        zoomCommand = .fit
        zoomRevision += 1
    }

    func focusTitle() {
        titleFocusRequest += 1
    }

    func zoom(_ command: ZoomCommand) {
        zoomCommand = command
        zoomRevision += 1
    }

    /// 正文现在的文字和富文本。没改过时为 nil。
    var editedBody: (text: String, rtf: Data?)? {
        guard bodyEdited, let textView else { return nil }
        let text = textView.string
        guard isRichText else { return (text, nil) }
        let attributed = textView.attributedString()
        let rtf = attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:])
        return (text, rtf)
    }

    var titleEdited: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines) != originalTitle
    }

    /// 修改已经交出去保存了。保存会重新查询、可能换掉选中项，又回到这里；先记下已保存，不会存第二次。
    func markSaved() {
        bodyEdited = false
        originalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 面板上方的预览窗口：看完整内容，改文字和标题，⌘N 写新的文本（#10）。
///
/// 打开时不取得键盘焦点，面板上的空格、esc、← → 和 ↩ 照常起作用，预览跟着选中的卡片换内容。
/// 点进正文或标题开始编辑时窗口才成为 key，这时按键交给它，esc 关闭。改动在关闭时保存。
@MainActor
final class PreviewController: NSObject, NSWindowDelegate {
    let window = AuxiliaryPanel()
    let state = PreviewState()
    private let model: HistoryModel
    /// 窗口失去键盘焦点。交给 `PanelController` 判断焦点去了哪里。
    var onResignKey: () -> Void = {}
    /// 预览关掉了。键盘焦点在预览上时，要还给面板。
    var onClose: () -> Void = {}

    static let maxSize = CGSize(width: 760, height: 560)
    static let minHeight: CGFloat = 260

    init(model: HistoryModel) {
        self.model = model
        super.init()
        window.delegate = self
        // 点图片、按钮时不抢键盘焦点；点进正文、标题时才成为 key。
        window.becomesKeyOnlyIfNeeded = true
        window.setContent(PreviewView(state: state, model: model, close: { [weak self] in self?.close() }))
    }

    var isVisible: Bool { window.isVisible }

    /// 按 `request` 打开预览，放在 `panelFrame`（面板的位置）上方。
    func open(_ request: PreviewRequest, above panelFrame: NSRect) {
        if isVisible { saveEdits() }
        switch request {
        case .show(let item), .edit(let item), .rename(let item):
            state.load(item, content: model.content(of: item.id))
        case .newText:
            state.load(nil, content: nil)
        }
        place(above: panelFrame)
        if !isVisible {
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                window.animator().alphaValue = 1
            }
        }
        switch request {
        case .show:
            // 窗口第一次上屏时 AppKit 会让标题框成为第一响应者，标题看起来是选中的。只是看的时候不要它。
            if window.firstResponder !== window, !window.isKeyWindow {
                window.makeFirstResponder(nil)
            }
        case .edit, .newText:
            window.makeKey()
            DispatchQueue.main.async { [weak self] in
                // 先让 SwiftUI 按新的内容排好版，正文编辑器才是这次的。
                self?.window.layoutIfNeeded()
                guard let self, let textView = self.state.textView else { return }
                self.window.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            }
        case .rename:
            window.makeKey()
            DispatchQueue.main.async { [weak self] in self?.state.focusTitle() }
        }
    }

    /// 选中的卡片变了：保存当前的修改，换成新的条目。正在新建文本时不换。
    func follow(_ item: ClipItem?) {
        guard isVisible, !state.isNewText, let item, item.id != state.item?.id else { return }
        saveEdits()
        state.load(item, content: model.content(of: item.id))
    }

    /// 关闭预览，保存修改。
    func close() {
        guard isVisible else { return }
        saveEdits()
        window.orderOut(nil)
        state.load(nil, content: nil)
        onClose()
    }

    private func saveEdits() {
        let body = state.editedBody
        let titleEdited = state.titleEdited
        let title = state.title
        state.markSaved()
        if state.isNewText {
            if let body {
                model.addText(body.text, rtf: body.rtf, title: title)
            }
        } else if let item = state.item, body != nil || titleEdited {
            model.saveEdits(of: item.id, text: body?.text, rtf: body?.rtf, title: title)
        }
    }

    /// 处理预览窗口是 key 时的按键，返回 true 表示已处理。esc 关闭预览（输入法组字时除外）。
    func handle(_ event: NSEvent) -> Bool {
        let composing = (window.firstResponder as? NSTextView)?.hasMarkedText() == true
        guard !composing else { return false }
        if event.keyCode == 53 { // esc
            close()
            return true
        }
        return false
    }

    private func place(above panelFrame: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(panelFrame) } ?? NSScreen.main
        let top = screen?.visibleFrame.maxY ?? panelFrame.maxY + Self.maxSize.height
        let width = min(Self.maxSize.width, panelFrame.width - 40)
        let height = max(Self.minHeight, min(Self.maxSize.height, top - panelFrame.maxY - 24))
        let frame = NSRect(x: panelFrame.midX - width / 2, y: panelFrame.maxY + 12, width: width, height: height)
        window.setFrame(frame, display: true)
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { onResignKey() }
    }
}

// MARK: - 视图

private struct PreviewView: View {
    let state: PreviewState
    let model: HistoryModel
    let close: () -> Void
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .onChange(of: state.titleFocusRequest) { titleFocused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: state.item?.kind.symbolName ?? ClipKind.text.symbolName)
                .foregroundStyle((state.item?.kind ?? .text).color)
                .frame(width: 18)
            TextField(state.isNewText ? "新建文本，可以起个标题" : "添加标题", text: Bindable(state).title)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .focused($titleFocused)
            Spacer(minLength: 8)
            Text(details)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button(action: close) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭预览（esc）")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    /// 类型、长度、来源和时间。
    private var details: String {
        guard let item = state.item else { return "PasteMe" }
        var parts = [item.typeTitle]
        if item.kind == .text { parts.append("\(item.textLength) 个字符") }
        if let source = item.sourceName { parts.append("来自\(source)") }
        parts.append(item.createdAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        switch state.item?.kind {
        case nil, .text:
            PreviewTextEditor(state: state)
        case .link:
            VStack(spacing: 0) {
                if let item = state.item {
                    LinkSummary(item: item)
                    Divider()
                }
                PreviewTextEditor(state: state)
            }
        case .image:
            if let data = state.content?.image, let image = NSImage(data: data) {
                VStack(spacing: 0) {
                    ZoomableImage(image: image, state: state)
                    if let text = state.item?.recognizedText, !text.isEmpty {
                        Divider()
                        RecognizedTextBar(text: text, model: model)
                    }
                }
            } else {
                missing("图片读不出来")
            }
        case .file:
            let urls = state.content?.fileURLs ?? []
            if let url = urls.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                VStack(spacing: 0) {
                    QuickLookView(url: url)
                    if urls.count > 1 {
                        Divider()
                        Text(urls.map(\.lastPathComponent).joined(separator: "、"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .padding(8)
                    }
                }
            } else {
                missing("文件已经不在原来的地方了\n" + urls.map(\.path).joined(separator: "\n"))
            }
        }
    }

    private func missing(_ message: String) -> some View {
        Text(message)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding()
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if state.item?.kind == .image {
                zoomButton("minus.magnifyingglass", "缩小", .zoomOut)
                zoomButton("plus.magnifyingglass", "放大", .zoomIn)
                Button("适合窗口") { state.zoom(.fit) }
                Button("实际大小") { state.zoom(.actualSize) }
            }
            Spacer()
            Text(hint)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .frame(height: 32)
    }

    private func zoomButton(_ symbol: String, _ help: String, _ command: PreviewState.ZoomCommand) -> some View {
        Button { state.zoom(command) } label: { Image(systemName: symbol) }
            .help(help)
    }

    private var hint: String {
        if state.isNewText { return "写好后按 esc，存进历史" }
        if state.bodyIsEditable { return "点进正文或标题即可修改，关闭时保存   空格 / esc 关闭" }
        return "空格 / esc 关闭   ← → 看其他卡片"
    }
}

/// 链接的网页标题、预览图和网址，以及「在浏览器中打开」。
private struct LinkSummary: View {
    let item: ClipItem

    var body: some View {
        HStack(spacing: 12) {
            if LinkBanner.hasContent(item) {
                LinkBanner(item: item)
                    .frame(width: 120)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let title = item.linkTitle, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                }
                HStack(spacing: 4) {
                    if let data = item.linkIcon, let icon = NSImage(data: data) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 14, height: 14)
                    }
                    Text(item.preview.flatMap(URL.init(string:))?.host() ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let url = item.preview.flatMap(URL.init(string:)) {
                Button("在浏览器中打开") { NSWorkspace.shared.open(url) }
                    .controlSize(.small)
            }
        }
        .padding(12)
    }
}

/// 图片里识别出的文字，可以选中，也可以一键拷贝。
private struct RecognizedTextBar: View {
    let text: String
    let model: HistoryModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.viewfinder")
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 70)
            Button("拷贝文字") {
                // 带着 PasteMe 自己的标记，不会再被记成一条新的条目。
                PasteboardCodec.write(ClipContent(kind: .text, text: text), to: .general)
                model.onNotice("已拷贝图片中的文字", "doc.on.doc")
            }
            .controlSize(.small)
        }
        .padding(10)
    }
}

/// 正文编辑器：`NSTextView`，保留富文本格式，不做引号、破折号替换和拼写纠正，代码粘进来不会被改。
private struct PreviewTextEditor: NSViewRepresentable {
    let state: PreviewState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFindBar = true
        textView.textContainerInset = NSSize(width: 12, height: 10)
        state.textView = textView
        load(into: textView, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView,
              context.coordinator.revision != state.revision
        else { return }
        state.textView = textView
        load(into: textView, context: context)
    }

    private func load(into textView: NSTextView, context: Context) {
        context.coordinator.revision = state.revision
        let rich = state.isRichText
        textView.isRichText = rich
        textView.isEditable = state.bodyIsEditable
        // 富文本常带着黑色文字，深色模式下看不清，按文档的样子画在白底上。
        textView.drawsBackground = rich
        textView.backgroundColor = .white
        textView.appearance = rich ? NSAppearance(named: .aqua) : nil
        let plainAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.textColor,
        ]
        textView.typingAttributes = plainAttributes
        let content = state.content
        let attributed: NSAttributedString
        if rich, let rtf = content?.rtf, let text = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            attributed = text
        } else {
            attributed = NSAttributedString(string: content?.text ?? "", attributes: plainAttributes)
        }
        textView.textStorage?.setAttributedString(attributed)
        textView.undoManager?.removeAllActions()
        textView.scrollToBeginningOfDocument(nil)
        state.bodyEdited = false
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let state: PreviewState
        var revision = -1

        init(state: PreviewState) {
            self.state = state
        }

        func textDidChange(_ notification: Notification) {
            MainActor.assumeIsolated { state.bodyEdited = true }
        }
    }
}

/// 可以缩放的图片：触控板捏合、按钮放大缩小，打开时缩到正好放进窗口（不放大小图）。
private struct ZoomableImage: NSViewRepresentable {
    let image: NSImage
    let state: PreviewState

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ZoomingScrollView {
        let scroll = ZoomingScrollView()
        scroll.contentView = CenteringClipView()
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 8
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = NSImageView()
        return scroll
    }

    func updateNSView(_ scroll: ZoomingScrollView, context: Context) {
        if let imageView = scroll.documentView as? NSImageView, imageView.image !== image {
            imageView.image = image
            imageView.imageScaling = .scaleAxesIndependently
            imageView.frame = NSRect(origin: .zero, size: image.size)
            scroll.needsFit = true
            scroll.needsLayout = true
        }
        if context.coordinator.zoomRevision != state.zoomRevision {
            context.coordinator.zoomRevision = state.zoomRevision
            switch state.zoomCommand {
            case .fit: scroll.needsFit = true; scroll.needsLayout = true
            case .actualSize: scroll.setMagnification(1, centeredAt: scroll.documentCenter)
            case .zoomIn: scroll.setMagnification(scroll.magnification * 1.25, centeredAt: scroll.documentCenter)
            case .zoomOut: scroll.setMagnification(scroll.magnification / 1.25, centeredAt: scroll.documentCenter)
            }
        }
    }

    final class Coordinator {
        var zoomRevision = -1
    }
}

final class ZoomingScrollView: NSScrollView {
    /// 下次布局时缩到正好放进窗口。
    var needsFit = true

    var documentCenter: NSPoint {
        let visible = documentVisibleRect
        return NSPoint(x: visible.midX, y: visible.midY)
    }

    override func layout() {
        super.layout()
        guard needsFit, let size = documentView?.frame.size, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0
        else { return }
        needsFit = false
        magnification = min(1, min(bounds.width / size.width, bounds.height / size.height))
    }
}

/// 图片比窗口小时放在正中间。
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width {
            rect.origin.x = (document.frame.width - rect.width) / 2
        }
        if rect.height > document.frame.height {
            rect.origin.y = (document.frame.height - rect.height) / 2
        }
        return rect
    }
}

/// 系统的 Quick Look 预览，文件类型由系统决定怎么显示。
private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
