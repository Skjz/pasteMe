import AppKit
import Carbon.HIToolbox
import Observation
import PasteMeCore

/// 设置窗口的状态：各个开关现在的值、显示哪一页、等用户确认的操作。
///
/// 开关写进 `Settings` 以后，应用里其他要跟着变的地方（面板、Paste Stack、`HistoryModel`）由 `AppDelegate`
/// 通过 `on…` 回调接上。会删条目的操作先放进 `pending…`，视图弹出确认，用户确认后才执行。
@Observable
@MainActor
final class SettingsModel {
    enum Page: String, CaseIterable, Identifiable {
        case general
        case panel
        case linkPreview
        case history
        case aliases
        case about

        var id: String { rawValue }
    }

    /// 换成更短的自动清除期限、马上会删掉 `count` 个条目时，等用户确认。
    struct PendingRetention: Equatable {
        let retention: HistoryRetention
        let count: Int
    }

    var page = Page.general {
        // 换到别的页，录了一半的快捷键算取消。
        didSet { if page != oldValue { cancelRecording() } }
    }
    let aliases: AppAliasesModel

    private(set) var launchesAtLogin = false
    private(set) var accessibilityTrusted = false
    private(set) var playsSoundOnRecord = false
    private(set) var showDuringScreenSharing = false
    private(set) var pasteImagesAsFiles = false
    private(set) var copyEditedToClipboard = true
    private(set) var cursorStyle = CursorStyle.breathe
    private(set) var panelRepeatAction = PanelRepeatAction.cyclePinboard
    private(set) var fileApp = OpenApp.systemDefault
    private(set) var folderApp = OpenApp.systemDefault
    private(set) var linkPreviewMode = LinkPreviewMode.off
    private(set) var historyRetention = HistoryRetention.never
    private(set) var checksForUpdates = true
    private(set) var pendingRetention: PendingRetention?
    /// 等用户确认的清空历史，值是会保留下来的 Pinboard 条目数。
    private(set) var pendingClear: Int?

    /// 一个快捷键下面的提示：录下的组合不能用的原因（`isProblem`），或者保存后的提醒。
    struct ShortcutNote: Equatable {
        let text: String
        let isProblem: Bool
    }

    enum RecordingTarget: Equatable {
        case global(GlobalAction)
        case panel(PanelShortcutAction)
    }

    /// 各个功能现在的全局快捷键（#50、#67），清除了的不在里面。
    private(set) var shortcuts: [GlobalAction: KeyCombo] = [:]
    /// 面板内各个命令现在的快捷键（#69），清除了的不在里面。
    private(set) var panelShortcuts: [PanelShortcutAction: KeyCombo] = [:]
    /// 正在录制哪一项快捷键。
    private(set) var recordingTarget: RecordingTarget?
    private(set) var shortcutNotes: [GlobalAction: ShortcutNote] = [:]
    private(set) var panelShortcutNotes: [PanelShortcutAction: ShortcutNote] = [:]

    var recordingShortcut: GlobalAction? {
        if case .global(let action) = recordingTarget { return action }
        return nil
    }

    var recordingPanelShortcut: PanelShortcutAction? {
        if case .panel(let action) = recordingTarget { return action }
        return nil
    }

    /// 登录时启动现在是否打开（`SMAppService`）。测试替换它。
    @ObservationIgnored var loginItemEnabled: () -> Bool = { false }
    /// 打开或关掉登录时启动，失败时抛出错误。
    @ObservationIgnored var setLoginItemEnabled: (Bool) throws -> Void = { _ in }
    @ObservationIgnored var isAccessibilityTrusted: () -> Bool = { false }
    @ObservationIgnored var onOpenAccessibilitySettings: () -> Void = {}
    /// 打开提示音时先播一次，让用户知道是什么声音。
    @ObservationIgnored var onPlaySound: () -> Void = {}
    @ObservationIgnored var onScreenSharingChange: (Bool) -> Void = { _ in }
    @ObservationIgnored var onImagesAsFilesChange: (Bool) -> Void = { _ in }
    @ObservationIgnored var onCopyEditedChange: (Bool) -> Void = { _ in }
    @ObservationIgnored var onCursorStyleChange: (CursorStyle) -> Void = { _ in }
    @ObservationIgnored var onPanelRepeatActionChange: (PanelRepeatAction) -> Void = { _ in }
    /// 改了面板内的快捷键（#69）：通知面板立即按新组合响应。
    @ObservationIgnored var onPanelShortcutChange: ([PanelShortcutAction: KeyCombo]) -> Void = { _ in }
    /// 换了文件或文件夹的打开方式：参数是文件的、文件夹的。
    @ObservationIgnored var onOpenAppsChange: (OpenApp, OpenApp) -> Void = { _, _ in }
    /// 这个 bundle id 的应用装了没有：没装的编辑器和终端在「打开」里不能选。测试替换它。
    @ObservationIgnored var isInstalled: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    /// 用户点了「检查更新」。
    @ObservationIgnored var onCheckForUpdates: () -> Void = {}
    /// 打开了自动检查更新：到时间了就马上查一次。
    @ObservationIgnored var onAutoUpdateChange: () -> Void = {}
    /// 换了自动清除的期限：按新的期限马上清除一次。
    @ObservationIgnored var onRetentionChange: () -> Void = {}
    /// 开始（true）或结束（false）录制快捷键：录制时先注销 PasteMe 自己的全局快捷键，结束后按设置重新注册。
    @ObservationIgnored var onShortcutRecording: (Bool) -> Void = { _ in }
    /// 不在录制时改了快捷键（恢复默认）：按设置重新注册。
    @ObservationIgnored var onShortcutChange: () -> Void = {}
    /// 系统设置「键盘快捷键」里打开着这个组合（`SystemShortcuts`）。
    @ObservationIgnored var isReservedBySystem: (KeyCombo) -> Bool = { _ in false }
    /// 启动时或上次注册时没注册上的快捷键（`GlobalShortcuts.failed`）。
    @ObservationIgnored var failedShortcuts: () -> Set<GlobalAction> = { [] }

    @ObservationIgnored private let settings: PasteMeCore.Settings
    @ObservationIgnored private let store: ClipStore

    init(settings: PasteMeCore.Settings, store: ClipStore, appNames: AppNames) {
        self.settings = settings
        self.store = store
        aliases = AppAliasesModel(appNames: appNames, settings: settings)
    }

    /// 打开窗口时重新读一遍所有开关和历史里的应用。
    func reload() {
        refreshSystemState()
        aliases.reload()
        playsSoundOnRecord = settings.playsSoundOnRecord
        showDuringScreenSharing = settings.showDuringScreenSharing
        pasteImagesAsFiles = settings.pasteImagesAsFiles
        copyEditedToClipboard = settings.copyEditedToClipboard
        cursorStyle = settings.cursorStyle
        panelRepeatAction = settings.panelRepeatAction
        fileApp = settings.fileApp
        folderApp = settings.folderApp
        linkPreviewMode = settings.linkPreviewMode
        historyRetention = settings.historyRetention
        checksForUpdates = settings.checksForUpdates
        reloadShortcuts()
        shortcutNotes = [:]
        panelShortcutNotes = [:]
        for action in failedShortcuts() {
            shortcutNotes[action] = ShortcutNote(text: Self.notRegisteredNote, isProblem: true)
        }
    }

    /// 登录项和辅助功能权限可能在系统设置里改了，回到 PasteMe 时重新读。
    func refreshSystemState() {
        launchesAtLogin = loginItemEnabled()
        accessibilityTrusted = isAccessibilityTrusted()
    }

    // MARK: - 通用

    func setLaunchesAtLogin(_ on: Bool) {
        do {
            try setLoginItemEnabled(on)
        } catch {
            NSLog("PasteMe: 设置登录时启动失败：\(error)")
        }
        launchesAtLogin = loginItemEnabled()
    }

    func setPlaysSoundOnRecord(_ on: Bool) {
        settings.playsSoundOnRecord = on
        playsSoundOnRecord = on
        if on { onPlaySound() }
    }

    // MARK: - 关于

    func setChecksForUpdates(_ on: Bool) {
        settings.checksForUpdates = on
        checksForUpdates = on
        if on { onAutoUpdateChange() }
    }

    func checkForUpdates() {
        onCheckForUpdates()
    }

    func openAccessibilitySettings() {
        onOpenAccessibilitySettings()
    }

    // MARK: - 快捷键（#50、#67、#69）

    /// 点全局快捷键的按钮：开始录制；正在录制这一个时再点是取消。
    func toggleRecording(_ action: GlobalAction) {
        beginRecording(.global(action))
    }

    /// 点面板内快捷键的按钮：开始录制；正在录制这一个时再点是取消。
    func toggleRecording(_ action: PanelShortcutAction) {
        beginRecording(.panel(action))
    }

    private func beginRecording(_ target: RecordingTarget) {
        if recordingTarget == target {
            cancelRecording()
            return
        }
        let wasRecording = recordingTarget != nil
        clearTemporaryProblem(for: recordingTarget)
        switch target {
        case .global(let action): shortcutNotes[action] = nil
        case .panel(let action): panelShortcutNotes[action] = nil
        }
        recordingTarget = target
        if !wasRecording { onShortcutRecording(true) }
    }

    func cancelRecording() {
        guard let target = recordingTarget else { return }
        recordingTarget = nil
        clearTemporaryProblem(for: target)
        onShortcutRecording(false)
    }

    private func clearTemporaryProblem(for target: RecordingTarget?) {
        switch target {
        case .global(let action):
            if shortcutNotes[action]?.isProblem == true { shortcutNotes[action] = nil }
        case .panel(let action):
            if panelShortcutNotes[action]?.isProblem == true { panelShortcutNotes[action] = nil }
        case nil:
            break
        }
    }

    /// 录制时按下的键：esc 取消，⌫ 清除，其余的检查后保存。不能用时写明原因，接着录。
    func recordKey(_ combo: KeyCombo) {
        guard let target = recordingTarget else { return }
        if combo.modifiers.isEmpty, combo.keyCode == kVK_Escape {
            cancelRecording()
            return
        }
        if combo.modifiers.isEmpty, combo.keyCode == kVK_Delete || combo.keyCode == kVK_ForwardDelete {
            switch target {
            case .global(let action): finishRecording(action, saving: nil)
            case .panel(let action): finishPanelRecording(action, saving: nil)
            }
            return
        }
        switch target {
        case .global(let action):
            if let problem = ShortcutRules.problem(with: combo, for: action, current: shortcuts, isReservedBySystem: isReservedBySystem) {
                shortcutNotes[action] = ShortcutNote(text: problem, isProblem: true)
                return
            }
            finishRecording(action, saving: combo)
        case .panel(let action):
            let problem = ShortcutRules.problem(
                with: combo,
                for: action,
                current: panelShortcuts,
                fixedTitle: PanelKeymap.fixedShortcutTitle(for:),
                isReservedBySystem: isReservedBySystem
            )
            if let problem {
                panelShortcutNotes[action] = ShortcutNote(text: problem, isProblem: true)
                return
            }
            finishPanelRecording(action, saving: combo)
        }
    }

    /// 恢复默认。默认的组合已经给了另一个功能时不恢复，写明原因。
    func resetShortcut(_ action: GlobalAction) {
        cancelRecording()
        let combo = action.defaultCombo
        if let problem = ShortcutRules.problem(with: combo, for: action, current: shortcuts, isReservedBySystem: { _ in false }) {
            shortcutNotes[action] = ShortcutNote(text: problem, isProblem: true)
            return
        }
        settings.resetShortcut(for: action)
        reloadShortcuts()
        shortcutNotes[action] = PanelKeymap.isUsedByPanel(combo, shortcuts: panelShortcuts)
            ? ShortcutNote(text: Self.usedByPanelNote, isProblem: false)
            : nil
        onShortcutChange()
        noteIfNotRegistered(action)
    }

    /// 恢复面板内快捷键的默认值（#69）。默认的组合已经给了另一个面板功能时不恢复，写明原因。
    func resetShortcut(_ action: PanelShortcutAction) {
        cancelRecording()
        let combo = action.defaultCombo
        let problem = ShortcutRules.problem(
            with: combo,
            for: action,
            current: panelShortcuts,
            fixedTitle: PanelKeymap.fixedShortcutTitle(for:),
            isReservedBySystem: { _ in false }
        )
        if let problem {
            panelShortcutNotes[action] = ShortcutNote(text: problem, isProblem: true)
            return
        }
        settings.resetShortcut(for: action)
        reloadShortcuts()
        panelShortcutNotes[action] = globalClashNote(for: combo)
        onPanelShortcutChange(panelShortcuts)
    }

    private func finishRecording(_ action: GlobalAction, saving combo: KeyCombo?) {
        settings.setShortcut(combo, for: action)
        reloadShortcuts()
        recordingTarget = nil
        shortcutNotes[action] = combo.map { PanelKeymap.isUsedByPanel($0, shortcuts: panelShortcuts) } == true
            ? ShortcutNote(text: Self.usedByPanelNote, isProblem: false)
            : nil
        onShortcutRecording(false)
        noteIfNotRegistered(action)
    }

    private func finishPanelRecording(_ action: PanelShortcutAction, saving combo: KeyCombo?) {
        settings.setShortcut(combo, for: action)
        reloadShortcuts()
        recordingTarget = nil
        panelShortcutNotes[action] = combo.flatMap(globalClashNote(for:))
        onShortcutRecording(false)
        onPanelShortcutChange(panelShortcuts)
    }

    private func globalClashNote(for combo: KeyCombo) -> ShortcutNote? {
        guard let global = GlobalAction.allCases.first(where: { shortcuts[$0] == combo }) else { return nil }
        return ShortcutNote(text: "与全局快捷键「\(global.title)」冲突，会被优先拦截", isProblem: false)
    }

    private func noteIfNotRegistered(_ action: GlobalAction) {
        if failedShortcuts().contains(action) {
            shortcutNotes[action] = ShortcutNote(text: Self.notRegisteredNote, isProblem: true)
        }
    }

    private static let usedByPanelNote = "面板打开时会覆盖面板内的功能"
    /// 注册失败时的提示。别的应用注册了同一个组合时注册照样成功（见 `HotKeyCenter.register`），所以不猜原因。
    static let notRegisteredNote = "注册失败，请换一个组合"

    private func reloadShortcuts() {
        shortcuts = Dictionary(uniqueKeysWithValues: GlobalAction.allCases.compactMap { action in
            settings.shortcut(for: action).map { (action, $0) }
        })
        panelShortcuts = Dictionary(uniqueKeysWithValues: PanelShortcutAction.allCases.compactMap { action in
            settings.shortcut(for: action).map { (action, $0) }
        })
    }

    // MARK: - 面板

    func setCursorStyle(_ style: CursorStyle) {
        settings.cursorStyle = style
        cursorStyle = style
        onCursorStyleChange(style)
    }

    func setPanelRepeatAction(_ action: PanelRepeatAction) {
        settings.panelRepeatAction = action
        panelRepeatAction = action
        onPanelRepeatActionChange(action)
    }

    func setShowDuringScreenSharing(_ on: Bool) {
        settings.showDuringScreenSharing = on
        showDuringScreenSharing = on
        onScreenSharingChange(on)
    }

    func setPasteImagesAsFiles(_ on: Bool) {
        settings.pasteImagesAsFiles = on
        pasteImagesAsFiles = on
        onImagesAsFilesChange(on)
    }

    func setCopyEditedToClipboard(_ on: Bool) {
        settings.copyEditedToClipboard = on
        copyEditedToClipboard = on
        onCopyEditedChange(on)
    }

    /// 没装的应用不能选（视图里是灰的），这里也不接受。
    func setFileApp(_ app: OpenApp) {
        guard app.isAvailable(isInstalled: isInstalled) else { return }
        settings.fileApp = app
        fileApp = app
        onOpenAppsChange(fileApp, folderApp)
    }

    func setFolderApp(_ app: OpenApp) {
        guard app.isAvailable(isInstalled: isInstalled) else { return }
        settings.folderApp = app
        folderApp = app
        onOpenAppsChange(fileApp, folderApp)
    }

    // MARK: - 链接预览

    /// 每一档会请求什么写在页面上，选了就生效，不再另外弹窗确认。
    func setLinkPreviewMode(_ mode: LinkPreviewMode) {
        settings.linkPreviewMode = mode
        linkPreviewMode = mode
    }

    // MARK: - 历史

    /// 换成更短的期限、马上就要删掉条目时，先放进 `pendingRetention` 等确认：删除不能撤销。
    func chooseRetention(_ retention: HistoryRetention) {
        guard retention != historyRetention else { return }
        if let cutoff = retention.cutoff(), let count = try? store.unpinnedCount(before: cutoff), count > 0 {
            pendingRetention = PendingRetention(retention: retention, count: count)
        } else {
            applyRetention(retention)
        }
    }

    func confirmRetention() {
        guard let pending = pendingRetention else { return }
        pendingRetention = nil
        applyRetention(pending.retention)
    }

    func cancelRetention() {
        pendingRetention = nil
    }

    private func applyRetention(_ retention: HistoryRetention) {
        settings.historyRetention = retention
        historyRetention = retention
        onRetentionChange()
    }

    func requestClearHistory() {
        pendingClear = (try? store.keptCount()) ?? 0
    }

    func confirmClearHistory() {
        guard pendingClear != nil else { return }
        pendingClear = nil
        do {
            try store.clearHistory()
        } catch {
            NSLog("PasteMe: 清空历史失败：\(error)")
        }
    }

    func cancelClearHistory() {
        pendingClear = nil
    }
}
