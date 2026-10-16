import AppKit
import Carbon.HIToolbox
import PasteMeCore
import ServiceManagement

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: ClipStore!
    private var paster: Paster!
    private var model: HistoryModel!
    private var monitor: ClipboardMonitor!
    private var panel: PanelController!
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!

    private let pauseItem = NSMenuItem(title: "暂停记录", action: #selector(togglePause), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
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
        model.onPaste = { [weak self] item, mode in self?.paste(item, as: mode) }

        monitor = ClipboardMonitor(store: store) { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.model.reload()
        }
        monitor.start()

        hotKey = HotKey(keyCode: kVK_ANSI_V, modifiers: cmdKey | shiftKey) { [weak self] in
            self?.panel.toggle()
        }
        if hotKey == nil {
            NSLog("PasteMe: ⇧⌘V 注册失败，可能已被其他应用占用")
        }

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
    }

    #if DEBUG
    /// 调试用：弹出面板，把它渲染成 PNG 后退出。用于在没有屏幕录制权限时检查界面。
    /// `PASTEME_SNAPSHOT=/tmp/panel.png swift run PasteMe`
    private func writeSnapshot(to path: String) {
        panel.show()
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
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "PasteMe")

        let menu = NSMenu()
        menu.delegate = self

        let open = NSMenuItem(title: "打开历史", action: #selector(showPanel), keyEquivalent: "v")
        open.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(pauseItem)
        menu.addItem(loginItem)
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
        pauseItem.state = monitor.isPaused ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
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

    @objc private func togglePause() {
        monitor.isPaused.toggle()
        statusItem.button?.appearsDisabled = monitor.isPaused
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
