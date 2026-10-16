import AppKit
import PasteMeCore
import ServiceManagement

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: ClipStore!
    private var paster: Paster!
    private var model: HistoryModel!
    private var recorder: Recorder!
    private var enrichment: EnrichmentQueue!
    private var pasteStack: PasteStackController!
    private var monitor: ClipboardMonitor!
    private var panel: PanelController!
    private let hotKeys = HotKeyCenter()
    private let toast = Toast()
    private var statusItem: NSStatusItem!

    /// 没有暂停时是带子菜单的“暂停记录”，暂停时是“恢复记录”。在 `menuWillOpen` 里切换。
    private let pauseItem = NSMenuItem(title: "暂停记录", action: nil, keyEquivalent: "")
    private lazy var pauseMenu = makePauseMenu()
    private let pasteStackItem = NSMenuItem(title: "Paste Stack", action: #selector(togglePasteStack), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let screenSharingItem = NSMenuItem(title: "共享屏幕时显示面板", action: #selector(toggleShowDuringScreenSharing), keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "", action: #selector(openAccessibilitySettings), keyEquivalent: "")
    private let cursorStyleItem = NSMenuItem(title: "光标样式", action: nil, keyEquivalent: "")
    private let settings = Settings()

    override public init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            store = try ClipStore(path: ClipStore.defaultPath())
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法打开历史数据库"
            alert.informativeText = String(describing: error)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        paster = Paster(store: store, pasteboard: GeneralPasteboard(), keystroke: CGEventPasteKeystroke())
        model = HistoryModel(store: store)
        model.cursorStyle = settings.cursorStyle
        panel = PanelController(model: model)
        panel.showsDuringScreenSharing = settings.showDuringScreenSharing
        model.onPaste = { [weak self] item, mode in self?.paste(item, as: mode) }

        enrichment = EnrichmentQueue(store: store, recognizer: VisionTextRecognizer())
        enrichment.onEnriched = { [weak self] _ in self?.reloadPanelIfVisible() }
        let stack = PasteStack()
        recorder = Recorder(store: store, enrichment: enrichment, pasteStack: stack)
        recorder.onRecord = { [weak self] _ in self?.reloadPanelIfVisible() }
        pasteStack = PasteStackController(stack: stack, store: store, paster: paster, toast: toast)
        pasteStack.showsDuringScreenSharing = settings.showDuringScreenSharing
        pasteStack.isPanelVisible = { [weak self] in self?.panel.isVisible ?? false }
        pasteStack.isRecordingPaused = { [weak self] in self?.recorder.isPaused ?? false }
        pasteStack.onActiveChange = { [weak self] in self?.updateStatusIcon() }
        recorder.onPauseChange = { [weak self] in self?.pauseDidChange() }
        monitor = ClipboardMonitor(recorder: recorder)
        monitor.start()

        hotKeys.register(.panel) { [weak self] in self?.panel.toggle() }
        hotKeys.register(.pause) { [weak self] in self?.togglePause() }
        hotKeys.register(.pasteStack) { [weak self] in self?.pasteStack.toggle() }

        setUpStatusItem()
        panel.prewarm()

        #if DEBUG
        if let cycles = PanelBenchmark.requestedCycles {
            PanelBenchmark.run(panel: panel, store: store, cycles: cycles)
            return
        }
        if let path = ProcessInfo.processInfo.environment["PASTEME_SNAPSHOT"] {
            writeSnapshot(to: path)
            return
        }
        #endif

        if !Accessibility.isTrusted {
            Accessibility.requestTrust()
        }

        // 给以前的图片补做文字识别。等启动时的其他工作做完再开始，之后每条之间也会停一下。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.enrichment.backfill()
        }
    }

    private func reloadPanelIfVisible() {
        if panel.isVisible { model.reload() }
    }

    #if DEBUG
    /// 调试用：弹出面板，把它渲染成 PNG 后退出。用于在没有屏幕录制权限时检查界面。
    /// `PASTEME_SNAPSHOT=/tmp/panel.png swift run PasteMe`
    /// 加上 `PASTEME_SNAPSHOT_QUERY=…` 时先在搜索框里输入这段文字，例如 `type:图片 报销`。
    private func writeSnapshot(to path: String) {
        panel.show()
        if let query = ProcessInfo.processInfo.environment["PASTEME_SNAPSHOT_QUERY"] {
            model.query = query
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if let data = self.panel.snapshotPNG() {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }
    #endif

    // MARK: - 粘贴

    private func paste(_ item: ClipItem, as mode: PasteMode) {
        // 先收起面板，⌘V 才会落到目标应用上。
        panel.hide()
        do {
            if try paster.paste(item.id, as: mode, into: panel.targetApp) == .copiedOnly {
                Accessibility.requestTrust()
            }
        } catch {
            NSLog("PasteMe: 粘贴失败：\(error)")
        }
    }

    // MARK: - 菜单栏

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusIcon.normal

        let menu = NSMenu()
        menu.delegate = self

        let open = NSMenuItem(title: "打开历史", action: #selector(showPanel), keyEquivalent: "")
        open.showShortcut(.panel)
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(pauseItem)
        pasteStackItem.showShortcut(.pasteStack)
        menu.addItem(pasteStackItem)
        menu.addItem(loginItem)
        menu.addItem(screenSharingItem)
        menu.addItem(accessibilityItem)
        menu.addItem(cursorStyleItem)
        cursorStyleItem.submenu = makeCursorStyleMenu()
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "清空历史…", action: #selector(clearHistory), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 PasteMe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem.menu = menu
    }

    private func makeCursorStyleMenu() -> NSMenu {
        let menu = NSMenu()
        for style in CursorStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(chooseCursorStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            menu.addItem(item)
        }
        return menu
    }

    public func menuWillOpen(_ menu: NSMenu) {
        updatePauseItem()
        pasteStackItem.state = pasteStack.stack.isActive ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        screenSharingItem.state = settings.showDuringScreenSharing ? .on : .off
        for item in cursorStyleItem.submenu?.items ?? [] {
            item.state = item.representedObject as? String == model.cursorStyle.rawValue ? .on : .off
        }
        accessibilityItem.title = Accessibility.isTrusted ? "辅助功能权限：已开启" : "辅助功能权限：未开启（点此设置）"
    }

    @objc private func chooseCursorStyle(_ sender: NSMenuItem) {
        guard let style = (sender.representedObject as? String).flatMap(CursorStyle.init(rawValue:)) else { return }
        settings.cursorStyle = style
        model.cursorStyle = style
    }

    @objc private func showPanel() {
        panel.show()
    }

    // MARK: - 暂停记录

    private func makePauseMenu() -> NSMenu {
        let menu = NSMenu()
        for minutes in [5, 30, 60] {
            let title = minutes < 60 ? "暂停 \(minutes) 分钟" : "暂停 \(minutes / 60) 小时"
            let item = NSMenuItem(title: title, action: #selector(pauseFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = minutes
            menu.addItem(item)
        }
        let untilResumed = NSMenuItem(title: "直到手动恢复", action: #selector(pauseFromMenu(_:)), keyEquivalent: "")
        untilResumed.target = self
        untilResumed.showShortcut(.pause)
        menu.addItem(untilResumed)
        return menu
    }

    private func updatePauseItem() {
        if let until = recorder.pausedUntil, recorder.isPaused {
            pauseItem.submenu = nil
            pauseItem.action = #selector(resumeFromMenu)
            pauseItem.showShortcut(.pause)
            pauseItem.title = until == .distantFuture ? "恢复记录" : "恢复记录（\(Self.timeFormat.string(from: until)) 自动恢复）"
        } else {
            pauseItem.action = nil
            pauseItem.keyEquivalent = ""
            pauseItem.title = "暂停记录"
            pauseItem.submenu = pauseMenu
        }
    }

    /// 菜单里的定时暂停；`representedObject` 是分钟数，没有时一直暂停到手动恢复。
    @objc private func pauseFromMenu(_ sender: NSMenuItem) {
        if let minutes = sender.representedObject as? Int {
            recorder.pause(until: Date().addingTimeInterval(Double(minutes) * 60))
        } else {
            recorder.pause()
        }
    }

    @objc private func resumeFromMenu() {
        recorder.resume()
    }

    /// 全局快捷键：没有暂停时一直暂停到手动恢复，暂停中则恢复。
    private func togglePause() {
        recorder.isPaused ? recorder.resume() : recorder.pause()
    }

    @objc private func togglePasteStack() {
        pasteStack.toggle()
    }

    /// 暂停记录比 Paste Stack 更要紧：两者同时时显示暂停的图标。
    private func updateStatusIcon() {
        statusItem.button?.image = recorder.isPaused ? StatusIcon.paused
            : pasteStack.stack.isActive ? StatusIcon.pasteStack
            : StatusIcon.normal
    }

    private func pauseDidChange() {
        updateStatusIcon()
        guard let until = recorder.pausedUntil else {
            toast.show("已恢复记录", symbol: "play.circle")
            return
        }
        let detail = until == .distantFuture
            ? "再按 \(GlobalShortcut.pause.symbol) 恢复"
            : "\(Self.timeFormat.string(from: until)) 自动恢复"
        toast.show("已暂停记录", detail: detail, symbol: "pause.circle")
    }

    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    @objc private func toggleShowDuringScreenSharing() {
        settings.showDuringScreenSharing.toggle()
        panel.showsDuringScreenSharing = settings.showDuringScreenSharing
        pasteStack.showsDuringScreenSharing = settings.showDuringScreenSharing
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("PasteMe: 设置登录时启动失败：\(error)")
        }
    }

    @objc private func openAccessibilitySettings() {
        Accessibility.requestTrust()
        Accessibility.openSettings()
    }

    @objc private func clearHistory() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "清空全部剪贴板历史？"
        alert.informativeText = "此操作无法撤销。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.deleteAll()
        } catch {
            NSLog("PasteMe: 清空历史失败：\(error)")
        }
    }
}
