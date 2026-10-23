import AppKit
import PasteMeCore
import SwiftUI

/// 不激活 PasteMe 自身的浮动面板。
///
/// `.nonactivatingPanel` 让面板能接收键盘输入，同时原来的前台应用保持激活状态，
/// 这样关闭面板后直接发送 ⌘V 就会粘贴到用户原本所在的应用里。
final class ClipPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // 呼出和收起的动画由 PanelAnimator 负责，不要系统自带的窗口动画。
        // 收起时依赖这一点：开着系统动画时，窗口 orderOut 后再放回屏幕会先播系统的过渡，
        // 这期间窗口服务器不理会 setFrameOrigin，面板只会原地淡出。
        animationBehavior = .none
        // 默认不出现在共享屏幕、录屏和截图里，见 `PanelController.showsDuringScreenSharing`。
        sharingType = .none
    }

    /// 收起动画期间为 false：面板还在屏幕上，但不再接收键盘焦点。
    var allowsKey = true

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// 管理历史面板的显示、隐藏、位置、动画、键盘操作和拖出卡片，以及面板上方的预览窗口和 Pinboard 编辑窗口。
@MainActor
final class PanelController: NSObject, NSWindowDelegate, NSDraggingSource {
    static let panelHeight: CGFloat = 330
    static let margin: CGFloat = 8

    private let panel = ClipPanel()
    private let model: HistoryModel
    private let dust = CardDust()
    private let hosting: NSHostingView<HistoryView>
    private let preview: PreviewController
    private let pinboardEditor: PinboardEditorController
    private var keyMonitor: Any?
    private lazy var animator = PanelAnimator(window: panel)

    /// 拖出卡片时交给拖拽的内容（`Paster.draggingWriters`）。
    var draggingWriters: (ClipItem) throws -> [NSPasteboardWriting] = { _ in [] }

    private enum Phase {
        case hidden, showing, shown, hiding
    }

    private var phase = Phase.hidden

    /// 面板正在呼出或已经就位。收起动画进行中算作不可见，这时再按 ⇧⌘V 会让面板滑回来。
    var isVisible: Bool { phase == .showing || phase == .shown }
    /// 最近一次呼出面板时的前台应用，粘贴的内容会送到这里。
    private(set) var targetApp: TargetApp?

    /// 共享屏幕、录屏和截图时能否看到面板。默认看不到，本机屏幕上照常显示。预览窗口和编辑窗口跟着面板。
    var showsDuringScreenSharing = false {
        didSet {
            let sharing: NSWindow.SharingType = showsDuringScreenSharing ? .readOnly : .none
            for window in [panel, preview.window, pinboardEditor.window] as [NSWindow] {
                window.sharingType = sharing
            }
        }
    }

    init(model: HistoryModel) {
        self.model = model
        hosting = NSHostingView(rootView: HistoryView(model: model, dust: dust))
        preview = PreviewController(model: model)
        pinboardEditor = PinboardEditorController(model: model)
        super.init()

        model.removalEffect = dust
        model.onPreview = { [weak self] in self?.openPreview($0) }
        model.onEditPinboard = { [weak self] in self?.openPinboardEditor($0) }
        model.onBeginDrag = { [weak self] in self?.beginDrag($0) }
        model.onSelectionChange = { [weak self] in
            guard let self, self.preview.isVisible else { return }
            self.preview.follow(self.model.selectedItem)
        }
        model.onWillEditTitle = { [weak self] in self?.preview.close() }
        preview.onResignKey = { [weak self] in self?.keyMovedAway() }
        pinboardEditor.onResignKey = { [weak self] in
            // 点回面板时编辑窗口关掉，当作取消。
            self?.pinboardEditor.close()
            self?.keyMovedAway()
        }
        preview.onClose = { [weak self] in self?.takeKeyBack() }
        pinboardEditor.onClose = { [weak self] in self?.takeKeyBack() }
        panel.contentView = WindowBackground.make(cornerRadius: 16, material: .popover, content: hosting)
        panel.delegate = self
    }

    /// 应用启动后调用一次，提前做好第一次呼出时才会做的准备工作。
    func prewarm() {
        animator.prepare()
        DustPipeline.shared.prepare()
    }

    /// 全局快捷键：面板没开时呼出；开着时有 Pinboard 就切到下一个标签，没有就收起。
    func toggle() {
        guard isVisible else { return show() }
        if model.pinboards.isEmpty {
            hide()
        } else {
            model.cycleTab(by: 1)
        }
    }

    func show() {
        guard !isVisible else { return }
        // 面板不激活 PasteMe，呼出前的前台应用就是目标应用。
        targetApp = NSWorkspace.shared.frontmostApplication.map {
            TargetApp(bundleID: $0.bundleIdentifier, name: $0.localizedName)
        }

        if phase == .hiding {
            // 收起动画进行到一半时再次呼出：面板还在屏幕上，恢复接收输入，从当前位置滑回去，留在原来的屏幕上。
            panel.allowsKey = true
            panel.ignoresMouseEvents = false
        } else {
            // 出现在鼠标所在的屏幕底部。
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            guard let visible = screen?.visibleFrame else { return }
            let frame = NSRect(
                x: visible.minX + Self.margin,
                y: visible.minY + Self.margin,
                width: visible.width - Self.margin * 2,
                height: Self.panelHeight
            )
            panel.setFrame(frame, display: false)
            animator.shownFrame = frame
            animator.jump(to: 0)
        }

        phase = .showing
        model.isPanelVisible = true
        model.didShow()
        panel.makeKeyAndOrderFront(nil)
        // 窗口第一次成为 key 时，AppKit 会把键盘焦点交给第一个能输入的视图，也就是搜索框。
        // 呼出时焦点在卡片列表上，交还给窗口本身。
        if model.focus == .cards {
            panel.makeFirstResponder(nil)
        }
        installKeyMonitor()
        // 用 ⇧⌘V 呼出时 ⌘ 往往还按着：一直按着就照样显示 ⌘1…⌘9，马上松开就不显示。
        shortcutKeysChanged(NSEvent.modifierFlags)
        animator.animate(to: 1, spring: .show) { [weak self] in
            self?.phase = .shown
        }
    }

    /// 收起面板。键盘焦点立即还给目标应用，之后才播放收起动画，所以随后发送的 ⌘V 不用等动画结束。
    func hide() {
        guard isVisible else { return }
        phase = .hiding
        // 标题栏里正在输入的标题、预览里的修改在这里保存；编辑窗口当作取消。它们关掉时不用把键盘焦点还给面板。
        model.panelWillHide()
        closingAuxiliaryWindows = true
        preview.close()
        pinboardEditor.close()
        closingAuxiliaryWindows = false
        removeKeyMonitor()
        panel.allowsKey = false
        panel.ignoresMouseEvents = true
        // orderOut 让面板交出键盘焦点（会触发 windowDidResignKey，此时已是 .hiding，不会重复收起），
        // 再不取得焦点地放回屏幕，由面板自己播放收起动画。这一步依赖 ClipPanel 关掉了系统窗口动画。
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        animator.animate(to: 0, spring: .hide) { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.panel.allowsKey = true
            self.panel.ignoresMouseEvents = false
            self.phase = .hidden
            self.model.isPanelVisible = false
            self.model.panelDidHide()
        }
    }

    #if DEBUG
    /// 基准用：面板窗口。
    var window: NSWindow { panel }

    enum SnapshotWindow { case panel, preview, pinboardEditor }

    func snapshotPNG(of which: SnapshotWindow = .panel) -> Data? {
        let window: NSWindow = switch which {
        case .panel: panel
        case .preview: preview.window
        case .pinboardEditor: pinboardEditor.window
        }
        guard window.isVisible, let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
    #endif

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { keyMovedAway() }
    }

    // MARK: - 预览和编辑窗口

    /// 正在收起面板、顺带关掉预览和编辑窗口。
    private var closingAuxiliaryWindows = false

    /// 面板、预览或编辑窗口失去了键盘焦点。焦点可能只是在它们之间换了一下（点进预览的正文），
    /// 等这次切换做完再看：去了别的应用时收起面板，和以前点击其他地方时一样。
    private func keyMovedAway() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            let ours: [NSWindow] = [self.panel, self.preview.window, self.pinboardEditor.window]
            if let key = NSApp.keyWindow, ours.contains(where: { $0 === key }) { return }
            self.hide()
        }
    }

    /// 预览或编辑窗口关掉后，键盘焦点回到面板的卡片上。
    private func takeKeyBack() {
        guard isVisible, !closingAuxiliaryWindows else { return }
        panel.makeKey()
        if model.focus == .cards {
            panel.makeFirstResponder(nil)
        }
        // 用 ⌘W 关掉预览时 ⌘ 还按着。
        shortcutKeysChanged(NSEvent.modifierFlags)
    }

    private func openPreview(_ request: PreviewRequest) {
        guard isVisible else { return }
        pinboardEditor.close()
        preview.open(request, above: panel.frame)
    }

    private func openPinboardEditor(_ request: PinboardEditRequest) {
        guard isVisible else { return }
        preview.close()
        pinboardEditor.open(request, above: panel.frame)
    }

    // MARK: - 拖出卡片

    /// 从面板上拖出卡片（#12）：内容和粘贴时写进剪贴板的一样，图片同时给出图片数据和一个 PNG 文件。
    /// 拖出面板时面板收起，免得挡住放下的位置；在面板里还可以拖到 Pinboard 的标签上固定，或在 Pinboard 里排序。
    private func beginDrag(_ item: ClipItem) {
        guard model.draggingID == nil, let event = NSApp.currentEvent, event.type == .leftMouseDragged,
              NSEvent.pressedMouseButtons & 1 != 0
        else { return }
        let writers: [NSPasteboardWriting]
        do {
            writers = try draggingWriters(item)
        } catch PasteError.filesMissing {
            model.onNotice("文件已经不在原来的地方了", "questionmark.folder")
            return
        } catch {
            NSLog("PasteMe: 拖出条目失败：\(error)")
            return
        }
        guard !writers.isEmpty else { return }

        let image = dragImage(for: item)
        let size = NSSize(width: ClipCardView.size.width * 0.6, height: ClipCardView.size.height * 0.6)
        let location = hosting.convert(event.locationInWindow, from: nil)
        let draggingItems = writers.enumerated().map { index, writer in
            let dragging = NSDraggingItem(pasteboardWriter: writer)
            // 几个文件叠在一起，错开一点。
            let offset = CGFloat(min(index, 3)) * 6
            dragging.setDraggingFrame(
                NSRect(x: location.x - size.width / 2 + offset, y: location.y - size.height / 2 + offset,
                       width: size.width, height: size.height),
                contents: image
            )
            return dragging
        }
        model.draggingID = item.id
        let session = hosting.beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    /// 拖拽时跟着鼠标的卡片图：和面板上的样子一样。
    private func dragImage(for item: ClipItem) -> NSImage {
        let dark = panel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let renderer = ImageRenderer(content: ClipCardView(item: item, shortcutIndex: nil)
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = panel.backingScaleFactor
        return renderer.nsImage ?? NSImage(size: ClipCardView.size)
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy, .generic] : .copy
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        MainActor.assumeIsolated {
            if isVisible, !panel.frame.contains(screenPoint) { hide() }
        }
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated { model.endDrag() }
    }

    // MARK: - 键盘

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        // 本地事件监视器总是在主线程上回调。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if event.type == .flagsChanged {
                    // 预览或编辑窗口在前面时，⌘数字 不是粘贴面板上的卡片，不显示提示。
                    self.shortcutKeysChanged(event.window === self.panel ? event.modifierFlags : [])
                    return false
                }
                if event.window === self.panel { return self.handle(event) }
                if event.window === self.preview.window { return self.preview.handle(event) }
                return false
            }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// 按住 ⌘ 时卡片上显示 ⌘1…⌘9（#39），规则见 `PanelKeymap.showsShortcutHints`，推迟显示见 `HistoryModel`。
    private func shortcutKeysChanged(_ modifiers: NSEvent.ModifierFlags) {
        model.shortcutKeysChanged(held: PanelKeymap.showsShortcutHints(
            command: modifiers.contains(.command),
            option: modifiers.contains(.option),
            control: modifiers.contains(.control)
        ))
    }

    /// 处理面板上的快捷键，返回 true 表示已处理、不再交给搜索框。按键规则见 `PanelKeymap`。
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = PanelKey(
            keyCode: Int(event.keyCode),
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control),
            characters: event.characters ?? ""
        )
        let context = PanelContext(
            focus: model.focus,
            queryIsEmpty: model.query.isEmpty,
            canUndoDelete: model.canUndoDelete,
            filtersActive: model.filters.isActive,
            suggestionsShown: model.showsSuggestions,
            // 编辑搜索框时第一响应者是它的字段编辑器。
            composing: (panel.firstResponder as? NSTextView)?.hasMarkedText() == true,
            previewShown: preview.isVisible
        )

        switch PanelKeymap.action(for: key, in: context) {
        case .passThrough:
            return false
        case .focusSearchThenPassThrough:
            // 监视器在事件分发之前回调，这里同步换掉第一响应者，这次按键就会落进搜索框。
            if let field = searchField(in: panel.contentView) {
                panel.makeFirstResponder(field)
            }
            model.focus = .search
            return false
        case .run(let command):
            run(command)
            return true
        }
    }

    private func run(_ command: PanelCommand) {
        switch command {
        case .close:
            hide()
        case .clearSearch:
            // 回到刚呼出面板时的样子。
            model.clearSearch()
            model.focus = .cards
        case .moveSelection(let offset):
            model.moveSelection(by: offset)
            model.focus = .cards
        case .focus(let focus):
            model.focus = focus
        case .paste(let mode):
            model.paste(as: mode)
        case .pasteAt(let index, let mode):
            model.paste(at: index, as: mode)
        case .deleteSelected:
            model.delete()
        case .undoDelete:
            model.undoDelete()
        case .moveSuggestion(let offset):
            model.moveSuggestion(by: offset)
        case .acceptSuggestion:
            model.acceptSuggestion()
        case .dismissSuggestions:
            model.dismissSuggestions()
        case .togglePreview:
            preview.isVisible ? preview.close() : model.preview()
        case .closePreview:
            preview.close()
        case .editSelected:
            model.edit()
        case .newText:
            model.newText()
        case .switchTab(let offset):
            model.cycleTab(by: offset)
        case .pinSelected:
            model.pinToRecentPinboard()
        case .showInHistory:
            if model.canShowInHistory { model.showInHistory() }
        case .showConversions:
            showConversionMenu()
        case .renameSelected:
            model.rename()
        case .commitTitle:
            model.commitTitle()
            // 输入框随之去掉，键盘焦点回到卡片上。
            panel.makeFirstResponder(nil)
        case .cancelTitle:
            model.cancelTitle()
            panel.makeFirstResponder(nil)
        case .copySelected:
            model.copy()
        case .openSelected:
            model.open()
        }
    }

    /// ⌘T：在选中的卡片标题栏下面弹出「转换」菜单，和右键菜单里的一样（#27）。
    /// 卡片的位置取删除动画记下的布局（`CardDust` 的视图盖在卡片列表上，坐标和卡片的布局一致）。
    private func showConversionMenu() {
        guard let item = model.selectedItem, item.kind == .text || item.kind == .link,
              let frame = dust.visibleFrame(of: item.id)
        else { return }
        let options = model.conversionOptions(for: item)
        let menu = NSMenu()
        menu.autoenablesItems = false
        if options.isEmpty {
            let note = NSMenuItem(title: ConversionOption.tooLongNote, action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        for (index, option) in options.enumerated() {
            if index > 0, option.conversion == .encodeBase64 { menu.addItem(.separator()) }
            let entry = ClosureMenuItem(option.menuTitle(for: item.textSubtype)) { [weak self] in
                self?.model.convert(item, using: option.conversion)
            }
            entry.isEnabled = option.unavailableReason == nil
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        for algorithm in HashAlgorithm.allCases {
            menu.addItem(ClosureMenuItem(algorithm.title) { [weak self] in
                self?.model.computeHash(item, using: algorithm)
            })
        }
        menu.popUp(positioning: nil, at: CGPoint(x: frame.minX + 10, y: frame.minY + ClipCardView.headerHeight), in: dust.view)
    }

    /// SwiftUI 的 `TextField` 在 macOS 上由 `NSTextField` 实现。搜索框在视图层级里排在最前面；
    /// 另一个输入框是卡片标题栏里编辑标题时的（#33），那时焦点是 `.title`，不会走到这里。
    private func searchField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = searchField(in: subview) { return field }
        }
        return nil
    }
}
