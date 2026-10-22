import AppKit
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

    var page = Page.general
    let aliases: AppAliasesModel

    private(set) var launchesAtLogin = false
    private(set) var accessibilityTrusted = false
    private(set) var playsSoundOnRecord = false
    private(set) var showDuringScreenSharing = false
    private(set) var pasteImagesAsFiles = false
    private(set) var cursorStyle = CursorStyle.breathe
    private(set) var linkPreviewMode = LinkPreviewMode.off
    private(set) var historyRetention = HistoryRetention.never
    private(set) var pendingRetention: PendingRetention?
    /// 等用户确认的清空历史，值是会保留下来的 Pinboard 条目数。
    private(set) var pendingClear: Int?

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
    @ObservationIgnored var onCursorStyleChange: (CursorStyle) -> Void = { _ in }
    /// 换了自动清除的期限：按新的期限马上清除一次。
    @ObservationIgnored var onRetentionChange: () -> Void = {}

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
        cursorStyle = settings.cursorStyle
        linkPreviewMode = settings.linkPreviewMode
        historyRetention = settings.historyRetention
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

    func openAccessibilitySettings() {
        onOpenAccessibilitySettings()
    }

    // MARK: - 面板

    func setCursorStyle(_ style: CursorStyle) {
        settings.cursorStyle = style
        cursorStyle = style
        onCursorStyleChange(style)
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
        pendingClear = (try? store.pinnedCount()) ?? 0
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
