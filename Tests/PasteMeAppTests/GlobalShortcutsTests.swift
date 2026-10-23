import AppKit
import Carbon.HIToolbox
import Testing
@testable import PasteMeApp
import PasteMeCore

/// 全局快捷键的显示、注册和在设置窗口里录制（#50）。
@MainActor
@Suite final class GlobalShortcutsTests {
    let suiteName = "PasteMeTests.GlobalShortcuts.\(UUID().uuidString)"
    let settings: PasteMeCore.Settings
    let store: ClipStore
    let model: SettingsModel
    var recording: [Bool] = []

    /// 美式键盘布局里的几个键。
    static func usLayout(_ keyCode: Int) -> String? {
        [kVK_ANSI_V: "v", kVK_ANSI_C: "c", kVK_ANSI_K: "k", kVK_ANSI_1: "1"][keyCode]
    }

    static let all: KeyCombo.Modifiers = [.control, .option, .shift, .command]
    static let optionCommandK = KeyCombo(keyCode: kVK_ANSI_K, modifiers: [.option, .command])

    init() throws {
        settings = PasteMeCore.Settings(defaults: try #require(UserDefaults(suiteName: suiteName)))
        store = try ClipStore(path: ":memory:")
        model = SettingsModel(settings: settings, store: store, appNames: AppNames(store: store, settings: settings) { _ in [] })
        model.onShortcutRecording = { [unowned self] in recording.append($0) }
        model.reload()
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    // MARK: 显示

    @Test func combosAreShownLikeSystemMenus() {
        #expect(GlobalAction.panel.defaultCombo.symbol(character: Self.usLayout) == "⇧⌘V")
        #expect(GlobalAction.pasteStack.defaultCombo.symbol(character: Self.usLayout) == "⌃⇧⌘C")
        #expect(KeyCombo(keyCode: kVK_Space, modifiers: [.command, .option]).symbol(character: Self.usLayout) == "⌥⌘空格")
        #expect(KeyCombo(keyCode: kVK_F5, modifiers: [.control]).symbol(character: Self.usLayout) == "⌃F5")
        #expect(KeyCombo(keyCode: kVK_LeftArrow, modifiers: [.command]).symbol(character: Self.usLayout) == "⌘←")
        #expect(KeyCombo(keyCode: kVK_ANSI_1, modifiers: Self.all).symbol(character: Self.usLayout) == "⌃⌥⇧⌘1")
    }

    @Test func modifiersMatchCarbonAndAppKit() {
        #expect(GlobalAction.panel.defaultCombo.carbonModifiers == cmdKey | shiftKey)
        #expect(GlobalAction.pause.defaultCombo.carbonModifiers == cmdKey | shiftKey | controlKey)
        #expect(GlobalAction.panel.defaultCombo.keyCode == kVK_ANSI_V)
        #expect(GlobalAction.pasteStack.defaultCombo.keyCode == kVK_ANSI_C)
        #expect(Self.optionCommandK.modifierMask == [.option, .command])
        // 大写锁定和 fn 不算修饰键。
        #expect(KeyCombo(keyCode: UInt16(kVK_ANSI_K), flags: [.option, .command, .capsLock, .function]) == Self.optionCommandK)
    }

    @Test func theSystemIsAsked() {
        // 真实的键盘布局和系统快捷键：只检查取得到，具体的值随机器而变。
        #expect(KeyNames.layoutCharacter(for: kVK_ANSI_V)?.isEmpty == false)
        #expect(!SystemShortcuts.current().isEmpty)
    }

    @Test func systemShortcutsAreMatchedOnTheFourModifiers() {
        // 调度中心的 ⌃↑：系统记的修饰键里还带着 fn 那一位。
        let entries = [
            SystemShortcuts.Entry(keyCode: kVK_UpArrow, carbonModifiers: controlKey | 0x20000, enabled: true),
            SystemShortcuts.Entry(keyCode: kVK_Space, carbonModifiers: cmdKey, enabled: false),
        ]
        #expect(SystemShortcuts.contains(KeyCombo(keyCode: kVK_UpArrow, modifiers: [.control]), in: entries))
        #expect(!SystemShortcuts.contains(KeyCombo(keyCode: kVK_UpArrow, modifiers: [.control, .shift]), in: entries))
        // 关掉了的系统快捷键可以用。
        #expect(!SystemShortcuts.contains(KeyCombo(keyCode: kVK_Space, modifiers: [.command]), in: entries))
    }

    @Test func panelKeysAreRecognized() {
        #expect(PanelKeymap.isUsedByPanel(KeyCombo(keyCode: kVK_ANSI_P, modifiers: [.command])))
        #expect(PanelKeymap.isUsedByPanel(KeyCombo(keyCode: kVK_ANSI_1, modifiers: [.command, .shift])))
        #expect(!PanelKeymap.isUsedByPanel(GlobalAction.panel.defaultCombo))
        #expect(!PanelKeymap.isUsedByPanel(GlobalAction.pause.defaultCombo))
    }

    // MARK: 注册

    @Test func shortcutsAreRegisteredFromTheSettingsAndSuspendedWhileRecording() {
        // ⌃⌥⇧⌘F13…F15：不和常用快捷键、`HotKeyCenterTests` 用的键冲突。
        let combos = [kVK_F13, kVK_F14, kVK_F15].map { KeyCombo(keyCode: $0, modifiers: Self.all) }
        for (action, combo) in zip(GlobalAction.allCases, combos) {
            settings.setShortcut(combo, for: action)
        }
        let shortcuts = GlobalShortcuts(settings: settings)
        for action in GlobalAction.allCases { shortcuts.set(action) {} }
        shortcuts.registerAll()
        #expect(shortcuts.failed.isEmpty)
        // 同一个进程里同一个组合不能注册两次：注册着时探针注册不上，暂停后能注册上。
        let probe = HotKeyCenter()
        #expect(probe.register(keyCode: kVK_F13, modifiers: combos[0].carbonModifiers) {} == nil)

        shortcuts.suspend()
        let id = probe.register(keyCode: kVK_F13, modifiers: combos[0].carbonModifiers) {}
        #expect(id != nil)
        if let id { probe.unregister(id) }

        shortcuts.resume()
        #expect(shortcuts.failed.isEmpty)
        #expect(probe.register(keyCode: kVK_F13, modifiers: combos[0].carbonModifiers) {} == nil)
    }

    // MARK: 录制

    @Test func aRecordedComboIsSavedAndRecordingEnds() {
        model.toggleRecording(.panel)
        #expect(model.recordingShortcut == .panel && recording == [true])

        model.recordKey(Self.optionCommandK)

        #expect(settings.shortcut(for: .panel) == Self.optionCommandK)
        #expect(model.shortcuts[.panel] == Self.optionCommandK)
        #expect(model.recordingShortcut == nil && recording == [true, false])
        #expect(model.shortcutNotes[.panel] == nil)
    }

    @Test func escapeCancelsAndDeleteClears() {
        model.toggleRecording(.pause)
        model.recordKey(KeyCombo(keyCode: kVK_Escape, modifiers: []))
        #expect(settings.shortcut(for: .pause) == GlobalAction.pause.defaultCombo)
        #expect(model.recordingShortcut == nil && recording == [true, false])

        model.toggleRecording(.pause)
        model.recordKey(KeyCombo(keyCode: kVK_Delete, modifiers: []))
        #expect(settings.shortcut(for: .pause) == nil)
        #expect(model.shortcuts[.pause] == nil)
    }

    @Test func badCombosAreExplainedAndRecordingGoesOn() {
        model.toggleRecording(.panel)

        model.recordKey(KeyCombo(keyCode: kVK_ANSI_K, modifiers: [.shift]))
        #expect(model.shortcutNotes[.panel] == .init(text: "要带上 ⌘、⌃ 或 ⌥ 中的至少一个", isProblem: true))
        model.recordKey(GlobalAction.pasteStack.defaultCombo)
        #expect(model.shortcutNotes[.panel]?.text == "和「开启或退出 Paste Stack」的快捷键相同")

        // 都没有保存，还在录制。
        #expect(settings.shortcut(for: .panel) == GlobalAction.panel.defaultCombo)
        #expect(model.recordingShortcut == .panel && recording == [true])

        // 取消后去掉原因。
        model.cancelRecording()
        #expect(model.shortcutNotes[.panel] == nil)
    }

    @Test func systemShortcutsCannotBeRecorded() {
        let commandSpace = KeyCombo(keyCode: kVK_Space, modifiers: [.command])
        model.isReservedBySystem = { $0 == commandSpace }
        model.toggleRecording(.panel)
        model.recordKey(commandSpace)
        #expect(model.shortcutNotes[.panel]?.text == "系统已经用了这个组合")
    }

    @Test func aPanelKeyIsSavedWithAWarning() {
        model.toggleRecording(.pasteStack)
        model.recordKey(KeyCombo(keyCode: kVK_ANSI_P, modifiers: [.command]))
        #expect(settings.shortcut(for: .pasteStack) == KeyCombo(keyCode: kVK_ANSI_P, modifiers: [.command]))
        #expect(model.shortcutNotes[.pasteStack] == .init(text: "面板开着时，面板里这个组合原来的功能会用不了", isProblem: false))
    }

    @Test func resettingGoesBackToTheDefaultUnlessItIsTaken() {
        var changes = 0
        model.onShortcutChange = { changes += 1 }
        settings.setShortcut(Self.optionCommandK, for: .panel)
        settings.setShortcut(GlobalAction.panel.defaultCombo, for: .pause)
        model.reload()

        // ⇧⌘V 现在是暂停的快捷键，呼出面板不能恢复成它。
        model.resetShortcut(.panel)
        #expect(settings.shortcut(for: .panel) == Self.optionCommandK)
        #expect(model.shortcutNotes[.panel]?.text == "和「暂停或恢复记录」的快捷键相同")

        model.resetShortcut(.pause)
        model.resetShortcut(.panel)
        #expect(settings.shortcut(for: .panel) == GlobalAction.panel.defaultCombo)
        #expect(settings.shortcut(for: .pause) == GlobalAction.pause.defaultCombo)
        #expect(model.shortcutNotes.isEmpty && changes == 2)
    }

    @Test func switchingPagesCancelsRecording() {
        model.toggleRecording(.panel)
        model.page = .panel
        #expect(model.recordingShortcut == nil && recording == [true, false])
    }

    @Test func shortcutsThatDidNotRegisterAreShown() {
        model.failedShortcuts = { [.pause] }
        model.reload()
        #expect(model.shortcutNotes[.pause] == .init(text: SettingsModel.notRegisteredNote, isProblem: true))
    }
}
