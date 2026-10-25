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
    private var appNames: AppNames!
    private var settingsWindow: SettingsWindow!
    private var shortcuts: GlobalShortcuts!
    private let toast = Toast()
    private var statusItem: NSStatusItem!

    /// 没有暂停时是带子菜单的“暂停记录”，暂停时是“恢复记录”。在 `menuWillOpen` 里切换。
    private let pauseItem = NSMenuItem(title: "暂停记录", action: nil, keyEquivalent: "")
    private lazy var pauseMenu = makePauseMenu()
    private let pasteStackItem = NSMenuItem(title: "Paste Stack", action: #selector(togglePasteStack), keyEquivalent: "")
    private let openItem = NSMenuItem(title: "打开历史", action: #selector(showPanel), keyEquivalent: "")
    /// 「暂停记录」子菜单里的「直到手动恢复」，右边显示暂停的快捷键。
    private let untilResumedItem = NSMenuItem(title: "直到手动恢复", action: #selector(pauseFromMenu(_:)), keyEquivalent: "")
    /// 定期删除以文件粘贴、拖出图片时生成的临时文件。
    private var cleanupTimer: Timer?
    private var temporaryFiles: TemporaryFiles?
    /// 没有辅助功能权限就粘贴不了，只在没开时显示在菜单最前面。
    private let accessibilityItem = NSMenuItem(title: "辅助功能权限未开启（点此设置）", action: #selector(openAccessibilitySettings), keyEquivalent: "")
    private let settings = Settings()
    private let recordSound = SystemRecordSound()
    private lazy var updater = Updater(settings: settings, toast: toast)
    /// 查到新版本时显示在菜单最前面（`Updater.available`）。
    private let updateItem = NSMenuItem(title: "", action: #selector(offerUpdate), keyEquivalent: "")
    private let checkUpdateItem = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")

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

        temporaryFiles = (try? TemporaryFiles.defaultDirectory()).map(TemporaryFiles.init(directory:))
        let settings = settings
        paster = Paster(
            store: store,
            pasteboard: GeneralPasteboard(),
            keystroke: CGEventPasteKeystroke(),
            files: temporaryFiles,
            imagesAsFiles: { settings.pasteImagesAsFiles }
        )
        appNames = AppNames(store: store, settings: settings)
        model = HistoryModel(store: store, appNames: appNames, settings: settings)
        model.cursorStyle = settings.cursorStyle
        model.pastesImagesAsFiles = settings.pasteImagesAsFiles
        model.fileApp = settings.fileApp
        model.folderApp = settings.folderApp
        panel = PanelController(model: model)
        panel.showsDuringScreenSharing = settings.showDuringScreenSharing
        panel.draggingWriters = { [paster] item in try paster!.draggingWriters(for: item.id) }
        model.onPaste = { [weak self] item, mode in self?.paste(item, as: mode) }
        model.onCopy = { [paster] item in
            do {
                try paster!.copyToPasteboard(item.id, touching: false)
            } catch {
                NSLog("PasteMe: 拷贝失败：\(error)")
            }
        }
        model.onOpen = { [weak self] plan in self?.open(plan) }
        model.onEditAliases = { [weak self] bundleID in
            // 先收起面板，再打开设置窗口的「应用别名」页并定位到这个应用。
            self?.panel.hide()
            self?.settingsWindow.showAliases(focusing: bundleID)
        }
        model.onNotice = { [weak self] message, symbol in self?.toast.show(message, symbol: symbol) }

        enrichment = EnrichmentQueue(store: store, enrichers: [
            TextRecognitionEnricher(recognizer: VisionTextRecognizer()),
            // 每次都读设置：在菜单里关掉后，排着队的链接也不再获取。
            LinkPreviewEnricher(fetcher: HTMLPreviewFetcher()) { Settings().linkPreviewMode },
        ])
        enrichment.onEnriched = { [weak self] _ in self?.reloadPanelIfVisible() }
        model.onEdited = { [weak self] id in self?.enrichment.enqueue(id) }
        let stack = PasteStack()
        recorder = Recorder(
            store: store,
            enrichment: enrichment,
            pasteStack: stack,
            sound: recordSound,
            playsSound: { settings.playsSoundOnRecord }
        )
        recorder.onRecord = { [weak self] _ in self?.reloadPanelIfVisible() }
        pasteStack = PasteStackController(stack: stack, store: store, paster: paster, toast: toast)
        pasteStack.showsDuringScreenSharing = settings.showDuringScreenSharing
        pasteStack.isPanelVisible = { [weak self] in self?.panel.isVisible ?? false }
        pasteStack.isRecordingPaused = { [weak self] in self?.recorder.isPaused ?? false }
        pasteStack.onActiveChange = { [weak self] in self?.updateStatusIcon() }
        recorder.onPauseChange = { [weak self] in self?.pauseDidChange() }
        monitor = ClipboardMonitor(recorder: recorder)
        monitor.start()
        shortcuts = GlobalShortcuts(settings: settings)
        pasteStack.exitShortcut = { [weak self] in self?.shortcuts.symbol(for: .pasteStack) }
        settingsWindow = SettingsWindow(model: makeSettingsModel())

        shortcuts.set(.panel) { [weak self] in self?.panel.toggle() }
        shortcuts.set(.pause) { [weak self] in self?.togglePause() }
        shortcuts.set(.pasteStack) { [weak self] in self?.pasteStack.toggle() }
        shortcuts.registerAll()

        setUpMainMenu()
        setUpStatusItem()
        panel.prewarm()

        #if DEBUG
        if let cycles = PanelBenchmark.requestedCycles {
            PanelBenchmark.run(panel: panel, model: model, store: store, cycles: cycles)
            return
        }
        if let path = ProcessInfo.processInfo.environment["PASTEME_SNAPSHOT"] {
            writeSnapshot(to: path)
            return
        }
        // 调试用：启动后直接打开设置窗口的这一页（`SettingsModel.Page` 的 rawValue，例如 `aliases`），
        // 用在点不了菜单栏图标的时候。截图模式画不出侧栏的材质，要在真实屏幕上看。
        if let page = ProcessInfo.processInfo.environment["PASTEME_SHOW_SETTINGS"] {
            settingsWindow.show(SettingsModel.Page(rawValue: page))
        }
        #endif

        if !Accessibility.isTrusted {
            Accessibility.forgetStaleGrant()
            Accessibility.requestTrust()
        }

        // 给以前的图片补做文字识别。等启动时的其他工作做完再开始，之后每条之间也会停一下。
        // 同时在后台读出来源应用的各种名字，第一次搜索时不用在主线程上读。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.enrichment.backfill()
            self?.backfillTextSubtypes()
            Task { await self?.appNames.prefetch() }
            self?.removeExpiredFiles()
            self?.clearOldHistory()
        }
        // 自动检查更新等启动时的事都做完了再查。
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.updater.checkIfDue()
        }
        // 以文件粘贴、拖出图片时生成的临时文件，过一天删掉；打开了自动清除时清除旧的历史；
        // 距上次检查更新满一天时再查一次。
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.removeExpiredFiles()
                self?.clearOldHistory()
                self?.updater.checkIfDue()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cleanupTimer = timer
    }

    private func removeExpiredFiles() {
        guard let files = temporaryFiles else { return }
        Task.detached { files.removeExpired() }
    }

    /// 自动清除（#34）：删除不在 Pinboard 里、超过设定时间没用过的条目。面板开着时这次跳过，
    /// 免得卡片在用户眼前消失，一小时后再查。
    private func clearOldHistory() {
        guard let cutoff = settings.historyRetention.cutoff(), !panel.isVisible else { return }
        do {
            try store.deleteUnpinned(before: cutoff)
        } catch {
            NSLog("PasteMe: 自动清除历史失败：\(error)")
        }
    }

    /// 给升级前记下的文本条目分批补算子类型（#26）。识别在主线程上做（`ClipStore` 只在主线程用），
    /// 所以每批不多、批与批之间停一下，面板这时照常流畅。
    private func backfillTextSubtypes() {
        do {
            guard try store.backfillTextSubtypes(limit: 100) > 0 else { return }
            reloadPanelIfVisible()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.backfillTextSubtypes()
            }
        } catch {
            NSLog("PasteMe: 补算文本子类型失败：\(error)")
        }
    }

    private func reloadPanelIfVisible() {
        if panel.isVisible { model.reload() }
    }

    /// 设置窗口改了开关以后，让面板、Paste Stack 和记录跟着变。
    private func makeSettingsModel() -> SettingsModel {
        let settingsModel = SettingsModel(settings: settings, store: store, appNames: appNames)
        settingsModel.loginItemEnabled = { SMAppService.mainApp.status == .enabled }
        settingsModel.setLoginItemEnabled = { on in
            try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
        settingsModel.isAccessibilityTrusted = { Accessibility.isTrusted }
        settingsModel.onOpenAccessibilitySettings = { [weak self] in self?.openAccessibilitySettings() }
        settingsModel.onPlaySound = { [recordSound] in recordSound.play() }
        settingsModel.onScreenSharingChange = { [weak self] on in
            self?.panel.showsDuringScreenSharing = on
            self?.pasteStack.showsDuringScreenSharing = on
        }
        settingsModel.onImagesAsFilesChange = { [weak self] on in self?.model.pastesImagesAsFiles = on }
        settingsModel.onCursorStyleChange = { [weak self] style in self?.model.cursorStyle = style }
        settingsModel.onOpenAppsChange = { [weak self] files, folders in
            self?.model.fileApp = files
            self?.model.folderApp = folders
        }
        settingsModel.onShortcutRecording = { [weak self] recording in
            recording ? self?.shortcuts.suspend() : self?.shortcuts.resume()
        }
        settingsModel.onShortcutChange = { [weak self] in self?.shortcuts.registerAll() }
        settingsModel.isReservedBySystem = { combo in SystemShortcuts.contains(combo, in: SystemShortcuts.current()) }
        settingsModel.failedShortcuts = { [weak self] in self?.shortcuts.failed ?? [] }
        settingsModel.onRetentionChange = { [weak self] in self?.clearOldHistory() }
        settingsModel.onCheckForUpdates = { [weak self] in self?.updater.checkNow() }
        settingsModel.onAutoUpdateChange = { [weak self] in self?.updater.checkIfDue() }
        return settingsModel
    }

    #if DEBUG
    /// 调试用：弹出面板，把它渲染成 PNG 后退出。用于在没有屏幕录制权限时检查界面。
    /// `PASTEME_SNAPSHOT=/tmp/panel.png swift run PasteMe`
    /// 加上 `PASTEME_SNAPSHOT_QUERY=…` 时先在搜索框里输入这段文字，例如 `type:图片 报销`，焦点也移到搜索框，
    /// 和打字时一样；输入 `@` 可以检查候选列表。
    /// 加上 `PASTEME_SNAPSHOT_DELETE=1` 时删除选中的卡片，0.1 秒后再渲染：颗粒动画还在播放，
    /// 可以确认被删的卡片变成了空位、其他卡片没有移动（颗粒画在 Metal 图层上，不在渲染结果里）。
    /// 加上 `PASTEME_SNAPSHOT_TAB=n` 时切到第 n 个 Pinboard 的标签。
    /// 加上 `PASTEME_SNAPSHOT_PREVIEW=1` 时打开选中卡片的预览，`PASTEME_SNAPSHOT_EDITOR=1` 时打开新建 Pinboard 的窗口，
    /// 这两个窗口另存为 `<文件名>-preview.png`、`<文件名>-editor.png`。
    /// 加上 `PASTEME_SNAPSHOT_APPEARANCE=light` 或 `dark` 时不管系统设置，按浅色或深色外观画。
    /// 加上 `PASTEME_SNAPSHOT_RENAME=1` 时在选中卡片的标题栏里编辑标题（#33）。
    /// 加上 `PASTEME_SNAPSHOT_HINTS=n` 时往右选 n 张（卡片列表跟着滚动），再当作按住了 ⌘，画出 ⌘1…⌘9（#39）。
    private func writeSnapshot(to path: String) {
        let environment = ProcessInfo.processInfo.environment
        switch environment["PASTEME_SNAPSHOT_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        panel.show()
        if let tab = environment["PASTEME_SNAPSHOT_TAB"].flatMap(Int.init) {
            model.cycleTab(by: tab)
        }
        if environment["PASTEME_SNAPSHOT_PREVIEW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.model.preview() }
        }
        if environment["PASTEME_SNAPSHOT_RENAME"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.model.rename() }
        }
        if let offset = environment["PASTEME_SNAPSHOT_HINTS"].flatMap(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.model.moveSelection(by: offset)
                self.model.shortcutKeysChanged(held: true)
            }
        }
        if environment["PASTEME_SNAPSHOT_EDITOR"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.model.onEditPinboard(.create(pinning: nil)) }
        }
        if let query = environment["PASTEME_SNAPSHOT_QUERY"] {
            model.focus = .search
            model.query = query
        }
        if environment["PASTEME_SNAPSHOT_DELETE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                self.model.focus = .cards
                self.model.delete()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if let data = self.panel.snapshotPNG() {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            let base = (path as NSString).deletingPathExtension
            for (window, suffix) in [(PanelController.SnapshotWindow.preview, "preview"), (.pinboardEditor, "editor")] {
                if let data = self.panel.snapshotPNG(of: window) {
                    try? data.write(to: URL(fileURLWithPath: "\(base)-\(suffix).png"))
                }
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

    /// ⌘O（#51）：收起面板，打开的应用来到前面。同一个应用要打开的几个网址一起交给它。
    private func open(_ plan: OpenPlan) {
        panel.hide()
        var byApp: [String: [URL]] = [:]
        for target in plan.targets {
            guard let bundleID = target.appBundleID else {
                NSWorkspace.shared.open(target.url)
                continue
            }
            byApp[bundleID, default: []].append(target.url)
        }
        for (bundleID, urls) in byApp {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                // 刚刚还在、这时却找不到了：按访达的规则用系统默认的方式打开。
                urls.forEach { NSWorkspace.shared.open($0) }
                continue
            }
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { NSLog("PasteMe: 用 \(bundleID) 打开失败：\(error)") }
            }
        }
    }

    // MARK: - 菜单栏

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusIcon.normal

        // 菜单里只放常用的操作，开关都在设置窗口里。
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(updateItem)
        menu.addItem(accessibilityItem)
        menu.addItem(openItem)
        menu.addItem(.separator())
        menu.addItem(pauseItem)
        menu.addItem(pasteStackItem)
        menu.addItem(.separator())
        menu.addItem(checkUpdateItem)
        menu.addItem(NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "退出 PasteMe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem.menu = menu
    }

    /// 不显示的主菜单。PasteMe 没有菜单栏，但输入框的 ⌘X、⌘C、⌘V、⌘A、⌘Z 要靠「编辑」菜单里的项目才能用，
    /// ⌘W 关闭窗口也一样。
    private func setUpMainMenu() {
        let main = NSMenu()
        // 第一项是应用菜单，这里空着。
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)

        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem()
        windowItem.submenu = window
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    public func menuWillOpen(_ menu: NSMenu) {
        // 快捷键可能在设置里改过（#50），每次打开菜单时按现在的组合显示。
        openItem.showShortcut(shortcuts.combo(for: .panel))
        pasteStackItem.showShortcut(shortcuts.combo(for: .pasteStack))
        untilResumedItem.showShortcut(shortcuts.combo(for: .pause))
        updatePauseItem()
        pasteStackItem.state = pasteStack.stack.isActive ? .on : .off
        accessibilityItem.isHidden = Accessibility.isTrusted
        updateItem.isHidden = updater.available == nil
        updateItem.title = updater.available.map { "更新到 PasteMe \($0.version)…" } ?? ""
        updateItem.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
    }

    @objc private func offerUpdate() {
        if let release = updater.available { updater.offer(release) }
    }

    @objc private func checkForUpdates() {
        updater.checkNow()
    }

    @objc private func showPanel() {
        panel.show()
    }

    @objc private func showSettings() {
        settingsWindow.show()
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
        untilResumedItem.target = self
        menu.addItem(untilResumedItem)
        return menu
    }

    private func updatePauseItem() {
        if let until = recorder.pausedUntil, recorder.isPaused {
            pauseItem.submenu = nil
            pauseItem.action = #selector(resumeFromMenu)
            pauseItem.showShortcut(shortcuts.combo(for: .pause))
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
        let detail = until != .distantFuture ? "\(Self.timeFormat.string(from: until)) 自动恢复"
            : shortcuts.symbol(for: .pause).map { "再按 \($0) 恢复" } ?? "在菜单栏菜单里恢复"
        toast.show("已暂停记录", detail: detail, symbol: "pause.circle")
    }

    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    @objc private func openAccessibilitySettings() {
        Accessibility.requestTrust()
        Accessibility.openSettings()
    }
}
