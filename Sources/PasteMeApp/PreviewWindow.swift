import AppKit
import Observation
import PasteMeCore
import Quartz
import SwiftUI
import UniformTypeIdentifiers

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
    /// 图片的缩放：加一时执行 `zoomCommand`。
    private(set) var zoomRevision = 0
    private(set) var zoomCommand = ZoomCommand.fit
    @ObservationIgnored weak var textView: NSTextView?

    enum ZoomCommand { case fit, actualSize, zoomIn, zoomOut }

    /// 按 ⌘E、右键「编辑…」打开的：链接这时显示网址编辑器，不显示网页。
    private(set) var editing = false
    /// 文件条目里正在预览第几个文件。换条目时回到第一个还在的文件。
    private(set) var fileIndex = 0

    var fileURLs: [URL] { content?.fileURLs ?? [] }

    /// 正在预览的文件。不是文件条目时为 nil。
    var currentFileURL: URL? {
        fileURLs.indices.contains(fileIndex) ? fileURLs[fileIndex] : nil
    }

    /// 换成第 `index` 个文件，超出两头时从另一头接着数。
    func showFile(at index: Int) {
        let count = fileURLs.count
        guard count > 0 else { return }
        fileIndex = (index % count + count) % count
    }

    var isNewText: Bool { item == nil }
    /// 文本和新建的文本可以改正文；链接只在编辑时可以改，平时显示网页（#52）。
    var bodyIsEditable: Bool {
        guard let item else { return true }
        return item.kind == .text || (item.kind == .link && !showsWebPage)
    }
    /// 链接平时显示网页（#52）。不是网页的链接（mailto: 这类）照旧显示网址。
    var showsWebPage: Bool {
        !editing && item?.kind == .link && WebPreviewPolicy.start(for: content?.text ?? "") != nil
    }
    /// 正文按富文本编辑：复制时带着格式的文本。
    var isRichText: Bool { content?.rtf != nil && item?.kind == .text }

    func load(_ item: ClipItem?, content: ClipContent?, editing: Bool = false) {
        self.item = item
        self.content = content
        self.editing = editing
        title = item?.title ?? ""
        originalTitle = title
        bodyEdited = false
        fileIndex = fileURLs.firstIndex { FileManager.default.fileExists(atPath: $0.path) } ?? 0
        revision += 1
        zoomCommand = .fit
        zoomRevision += 1
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
    let web = WebPreviewLoader()
    private let model: HistoryModel
    /// 窗口失去键盘焦点。交给 `PanelController` 判断焦点去了哪里。
    var onResignKey: () -> Void = {}
    /// 预览关掉了。键盘焦点在预览上时，要还给面板。
    var onClose: () -> Void = {}

    /// 上次放预览时面板的位置。换内容时按新内容重新定大小。
    private var panelFrame: NSRect?

    init(model: HistoryModel) {
        self.model = model
        super.init()
        window.delegate = self
        // 点图片、按钮时不抢键盘焦点；点进正文、标题时才成为 key。
        window.becomesKeyOnlyIfNeeded = true
        window.setContent(PreviewView(
            state: state, model: model, web: web,
            close: { [weak self] in self?.close() },
            showFile: { [weak self] index in self?.showFile(at: index) }
        ))
    }

    var isVisible: Bool { window.isVisible }

    /// 按 `request` 打开预览，放在 `panelFrame`（面板的位置）上方。
    func open(_ request: PreviewRequest, above panelFrame: NSRect) {
        if isVisible { saveEdits() }
        switch request {
        case .show(let item):
            state.load(item, content: model.content(of: item.id))
        case .edit(let item):
            state.load(item, content: model.content(of: item.id), editing: true)
        case .newText:
            state.load(nil, content: nil)
        }
        showWebPage(after: 0)
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
        }
    }

    /// 选中的卡片变了：保存当前的修改，换成新的条目。正在新建文本时不换。
    func follow(_ item: ClipItem?) {
        guard isVisible, !state.isNewText, let item, item.id != state.item?.id else { return }
        saveEdits()
        state.load(item, content: model.content(of: item.id))
        showWebPage(after: WebPreviewLoader.followDelay)
        if let panelFrame { place(above: panelFrame) }
    }

    /// 几个文件的条目：换成预览第 `index` 个，窗口按这个文件重新定大小。
    func showFile(at index: Int) {
        guard isVisible, state.fileURLs.count > 1 else { return }
        state.showFile(at: index)
        if let panelFrame { place(above: panelFrame) }
    }

    /// 上一个、下一个文件（⌥← ⌥→）。
    func showFile(by offset: Int) {
        showFile(at: state.fileIndex + offset)
    }

    /// 预览的是链接时加载它的网页，否则停掉上一个网页。
    private func showWebPage(after delay: TimeInterval) {
        if state.showsWebPage, let address = state.content?.text {
            web.show(address, after: delay)
        } else {
            web.stop()
        }
    }

    /// 关闭预览，保存修改。
    func close() {
        guard isVisible else { return }
        saveEdits()
        window.orderOut(nil)
        web.stop(clearingData: true)
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
        // 点进 Quick Look 以后按键在预览上：⌥← ⌥→ 照样换文件。
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .option, state.fileURLs.count > 1, event.keyCode == 123 || event.keyCode == 124 {
            showFile(by: event.keyCode == 123 ? -1 : 1)
            return true
        }
        return false
    }

    /// 放在面板上方正中，大小按内容（`PreviewLayout`）。
    private func place(above panelFrame: NSRect) {
        self.panelFrame = panelFrame
        let screen = NSScreen.screens.first { $0.frame.intersects(panelFrame) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let available = PreviewLayout.available(above: panelFrame, in: visible)
        let size = PreviewLayout.size(for: layoutContent(), available: available)
        let frame = NSRect(x: panelFrame.midX - size.width / 2, y: panelFrame.maxY + 12, width: size.width, height: size.height)
        window.setFrame(frame, display: true)
    }

    private func layoutContent() -> PreviewLayout.Content {
        switch state.item?.kind {
        case .link where state.showsWebPage:
            return .page
        case .file:
            guard let url = state.currentFileURL, FileManager.default.fileExists(atPath: url.path) else { return .text(height: 80) }
            return PreviewLayout.content(forFileAt: url)
        case .image:
            let extra = (state.item?.recognizedText ?? "").isEmpty ? 0 : PreviewLayout.recognizedTextHeight
            return (state.content?.image).flatMap(NSImage.init(data:)).map { .fitted($0.size, extra: extra) } ?? .page
        case nil where state.isNewText:
            return .text(height: PreviewLayout.newTextHeight)
        default:
            let text: NSAttributedString
            if state.isRichText, let rtf = state.content?.rtf, let rich = NSAttributedString(rtf: rtf, documentAttributes: nil) {
                text = rich
            } else {
                text = NSAttributedString(string: state.content?.text ?? "", attributes: [.font: PreviewLayout.textFont])
            }
            return .text(height: PreviewLayout.height(of: text))
        }
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { onResignKey() }
    }
}

/// 预览窗口的大小：网页和放不进别的规则的文件用面板上方能用的整块地方；图片按原来的比例放进去，不放大；
/// 文本按内容的高度，宽度适合阅读。都加上顶上那条窄栏的高度。
@MainActor
enum PreviewLayout {
    enum Content: Equatable {
        case page
        /// 内容想要的大小（点），按比例缩进能用的地方，不放大。`extra` 是内容下面另外要的高度（图片里识别出的文字）。
        case fitted(CGSize, extra: CGFloat)
        /// 正文排好版的高度。
        case text(height: CGFloat)
    }

    static let minSize = CGSize(width: 360, height: 220)
    static let barHeight: CGFloat = 40
    static let textWidth: CGFloat = 720
    static let textFont = NSFont.systemFont(ofSize: 13)
    static let textInset = NSSize(width: 16, height: 10)
    static let newTextHeight: CGFloat = 220
    /// 图片下面识别出的文字那一栏最高多高。
    static let recognizedTextHeight: CGFloat = 90
    /// 文件夹、应用这类文件包：Quick Look 只显示一个大图标和几行信息。
    static let folderSize = CGSize(width: 560, height: 360)
    /// 超过这么长的文字不再量高度，直接用能用的最大高度。
    static let measuredLength = 20_000
    /// 不超过这么大的文本文件才读出来量高度。
    static let measuredFileSize = 256 * 1024
    /// Quick Look 显示文本文件用的字体和边距，量高度时照着估。
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let codeInset = NSSize(width: 24, height: 16)

    /// 面板上方能用的地方：宽度最多是屏幕的 80%，高度到屏幕顶端，留出 24 点。
    static func available(above panelFrame: NSRect, in visibleFrame: NSRect) -> CGSize {
        CGSize(width: min(panelFrame.width - 40, visibleFrame.width * 0.8), height: visibleFrame.maxY - panelFrame.maxY - 24)
    }

    static func size(for content: Content, available: CGSize) -> CGSize {
        let available = CGSize(width: max(available.width, minSize.width), height: max(available.height, minSize.height))
        switch content {
        case .page:
            return available
        case .fitted(let size, let extra):
            let room = CGSize(width: available.width, height: max(1, available.height - barHeight - extra))
            guard size.width > 0, size.height > 0 else { return available }
            let scale = min(1, room.width / size.width, room.height / size.height)
            return CGSize(
                width: max(minSize.width, (size.width * scale).rounded()),
                height: max(minSize.height, (size.height * scale).rounded() + barHeight + extra)
            )
        case .text(let height):
            let wanted = (height + barHeight).rounded(.up)
            return CGSize(width: min(textWidth, available.width), height: min(available.height, max(minSize.height, wanted)))
        }
    }

    /// 正文在 `textWidth` 宽的编辑器里排好版的高度，包括上下的边距。
    static func height(of text: NSAttributedString, inset: NSSize = textInset) -> CGFloat {
        guard text.length <= measuredLength else { return .greatestFiniteMagnitude }
        // NSTextView 的文字左右各有 5 点的 lineFragmentPadding。
        let width = textWidth - inset.width * 2 - 10
        let rect = text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return rect.height + inset.height * 2
    }

    /// 文件按类型：图片按图片的大小，文本和代码按行数，文件夹和应用是一个小窗口，其余（PDF、视频……）用整块地方。
    static func content(forFileAt url: URL) -> Content {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true {
            return .fitted(folderSize, extra: 0)
        }
        guard let type = values?.contentType else { return .page }
        if type.conforms(to: .image),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = properties[kCGImagePropertyPixelHeight] as? CGFloat {
            return .fitted(CGSize(width: width, height: height), extra: 0)
        }
        if type.conforms(to: .text), (values?.fileSize ?? .max) <= measuredFileSize,
           let text = try? String(contentsOf: url, encoding: .utf8) {
            let measured = height(of: NSAttributedString(string: text, attributes: [.font: codeFont]), inset: codeInset)
            return .text(height: measured)
        }
        return .page
    }
}

// MARK: - 视图

/// 预览窗口：顶上一条窄栏，下面是内容，左、右、下三边铺满。窄栏和窗口是同一层玻璃，没有分隔线，
/// 左边是标题（没有标题时是网站、文件名这类说明，点进去就能起标题），右边是这种内容的几个按钮和关闭，
/// 平时颜色很淡，鼠标进来才深一点。控件不叠在内容上，免得挡住网页、代码开头那几行。
private struct PreviewView: View {
    let state: PreviewState
    let model: HistoryModel
    let web: WebPreviewLoader
    let close: () -> Void
    /// 几个文件的条目换成预览第几个文件。
    let showFile: (Int) -> Void

    @State private var hovering = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            bar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if state.item?.kind == .image, let text = state.item?.recognizedText, !text.isEmpty {
                RecognizedTextBar(text: text, model: model)
            }
        }
        .onHover { hovering = $0 }
    }

    // MARK: 窄栏

    private var bar: some View {
        HStack(spacing: 8) {
            icon
            TextField(label, text: Bindable(state).title)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .focused($titleFocused)
                .help(state.isNewText ? "起个标题" : "点这里起标题、改标题")
            Spacer(minLength: 8)
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if state.fileURLs.count > 1 {
                fileSwitcher
            }
            actions
                .foregroundStyle(hovering || titleFocused ? .secondary : .tertiary)
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: PreviewLayout.barHeight)
    }

    @ViewBuilder
    private var icon: some View {
        if state.item?.kind == .link, let data = state.item?.linkIcon, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: state.item?.kind.symbolName ?? ClipKind.text.symbolName)
                .foregroundStyle((state.item?.kind ?? .text).color)
        }
    }

    /// 没有标题时标题框里的说明：网站、文件名或文本的长度。来源应用和时间卡片上已经有了，这里不再写。
    private var label: String {
        guard let item = state.item else { return "新建文本，可以起个标题" }
        switch item.kind {
        case .link:
            return (state.content?.text).flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines))?.host() } ?? item.typeTitle
        case .file:
            // 几个文件时，正在看哪一个写在右边的切换器上。
            let urls = state.fileURLs
            return urls.count > 1 ? "\(urls.count) 个文件" : urls.first?.lastPathComponent ?? item.typeTitle
        case .text:
            return "\(item.typeTitle) · \(item.textLength) 个字符"
        case .image:
            return item.typeTitle
        }
    }

    /// 几个文件时换着看：两边的箭头是上一个、下一个（⌥← ⌥→），点文件名列出所有文件。
    private var fileSwitcher: some View {
        let urls = state.fileURLs
        return HStack(spacing: 0) {
            action("chevron.left", "上一个文件（⌥←）") { showFile(state.fileIndex - 1) }
            Menu {
                ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                    Toggle(url.lastPathComponent, isOn: Binding(get: { index == state.fileIndex }, set: { _ in showFile(index) }))
                }
            } label: {
                Text(state.currentFileURL?.lastPathComponent ?? "")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(size: 12))
                    .frame(maxWidth: 240)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("选择要预览的文件")
            // 不放进菜单的标签里：菜单在 macOS 上只显示标签里的第一段文字。
            Text("\(state.fileIndex + 1) / \(urls.count)")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
            action("chevron.right", "下一个文件（⌥→）") { showFile(state.fileIndex + 1) }
        }
        .foregroundStyle(hovering || titleFocused ? .secondary : .tertiary)
    }

    /// 新建和编辑文本时的提示，别的时候没有。
    private var hint: String? {
        if state.isNewText { return "写好后按 esc，存进历史" }
        if state.editing { return "关闭时保存" }
        return nil
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 0) {
            switch state.item?.kind {
            case .link where state.showsWebPage:
                if let url = URL(string: (state.content?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) {
                    action("safari", "在浏览器中打开") { NSWorkspace.shared.open(url) }
                }
            case .image:
                action("minus.magnifyingglass", "缩小") { state.zoom(.zoomOut) }
                action("plus.magnifyingglass", "放大") { state.zoom(.zoomIn) }
                action("arrow.down.right.and.arrow.up.left", "适合窗口") { state.zoom(.fit) }
                action("1.magnifyingglass", "实际大小") { state.zoom(.actualSize) }
            case .file:
                if let item = state.item {
                    action("arrow.up.forward.app", "打开（⌘O）") { model.open(item) }
                }
            default:
                EmptyView()
            }
            action("xmark", "关闭（空格 / esc）", close)
        }
    }

    private func action(_ symbol: String, _ help: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        switch state.item?.kind {
        case nil, .text:
            PreviewTextEditor(state: state)
        case .link:
            if state.showsWebPage {
                WebPreviewPane(loader: web, address: state.content?.text ?? "")
            } else {
                PreviewTextEditor(state: state)
            }
        case .image:
            if let data = state.content?.image, let image = NSImage(data: data) {
                ZoomableImage(image: image, state: state)
            } else {
                missing("图片读不出来")
            }
        case .file:
            if let url = state.currentFileURL, FileManager.default.fileExists(atPath: url.path) {
                QuickLookView(url: url)
            } else {
                missing("文件已经不在原来的地方了\n" + (state.currentFileURL?.path ?? ""))
            }
        }
    }

    private func missing(_ message: String) -> some View {
        Text(message)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding()
    }
}

/// 图片里识别出的文字，可以选中，也可以一键拷贝。排在图片下面，不叠在图片上。
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
            .frame(maxHeight: PreviewLayout.recognizedTextHeight - 20)
            .fixedSize(horizontal: false, vertical: true)
            Button("拷贝文字") {
                // 带着 PasteMe 自己的标记，不会再被记成一条新的条目。
                PasteboardCodec.write(ClipContent(kind: .text, text: text), to: .general)
                model.onNotice("已拷贝图片中的文字", "doc.on.doc")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        textView.textContainerInset = PreviewLayout.textInset
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
            .font: PreviewLayout.textFont,
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
        scroll.documentView = FirstClickImageView()
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

    // 点图片不需要键盘：接受第一下点击，预览窗口不抢走面板的键盘焦点（见 `AuxiliaryPanel.sendEvent`）。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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

/// 预览里的图片：接受第一下点击，原因同 `ZoomingScrollView`。
final class FirstClickImageView: NSImageView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 图片比窗口小时放在正中间。
final class CenteringClipView: NSClipView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
