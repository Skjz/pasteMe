import AppKit
import Testing
@testable import PasteMeApp
import PasteMeCore

/// 设置窗口：开关存进 `Settings` 并通知应用，会删条目的操作先等确认，窗口大小固定。
@MainActor
@Suite final class SettingsWindowTests {
    let suiteName = "PasteMeTests.SettingsWindow.\(UUID().uuidString)"
    let settings: PasteMeCore.Settings
    let store: ClipStore
    let model: SettingsModel

    init() throws {
        settings = PasteMeCore.Settings(defaults: try #require(UserDefaults(suiteName: suiteName)))
        store = try ClipStore(path: ":memory:")
        model = SettingsModel(settings: settings, store: store, appNames: AppNames(store: store, settings: settings) { _ in [] })
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    @Test func togglesAreSavedAndPassedOnToTheApp() {
        var sharing: [Bool] = []
        var imagesAsFiles: [Bool] = []
        var cursorStyles: [CursorStyle] = []
        var soundsPlayed = 0
        model.onScreenSharingChange = { sharing.append($0) }
        model.onImagesAsFilesChange = { imagesAsFiles.append($0) }
        model.onCursorStyleChange = { cursorStyles.append($0) }
        model.onPlaySound = { soundsPlayed += 1 }

        model.setShowDuringScreenSharing(true)
        model.setPasteImagesAsFiles(true)
        model.setCursorStyle(.flow)
        model.setLinkPreviewMode(.siteIcon)
        model.setPlaysSoundOnRecord(true)
        model.setPlaysSoundOnRecord(false)

        #expect(settings.showDuringScreenSharing && model.showDuringScreenSharing && sharing == [true])
        #expect(settings.pasteImagesAsFiles && model.pasteImagesAsFiles && imagesAsFiles == [true])
        #expect(settings.cursorStyle == .flow && model.cursorStyle == .flow && cursorStyles == [.flow])
        #expect(settings.linkPreviewMode == .siteIcon && model.linkPreviewMode == .siteIcon)
        // 打开时先响一次，关掉时不响。
        #expect(!settings.playsSoundOnRecord && !model.playsSoundOnRecord && soundsPlayed == 1)
    }

    @Test func reloadReadsTheSettingsAndTheSystemState() {
        settings.pasteImagesAsFiles = true
        settings.historyRetention = .month
        model.loginItemEnabled = { true }
        model.isAccessibilityTrusted = { true }

        model.reload()

        #expect(model.pasteImagesAsFiles)
        #expect(model.historyRetention == .month)
        #expect(model.launchesAtLogin)
        #expect(model.accessibilityTrusted)
    }

    /// 打开登录项失败时，开关停在系统里实际的状态。
    @Test func launchAtLoginShowsTheRealStateWhenItFails() {
        struct Failure: Error {}
        var enabled = false
        model.loginItemEnabled = { enabled }
        model.setLoginItemEnabled = { _ in throw Failure() }
        model.setLaunchesAtLogin(true)
        #expect(!model.launchesAtLogin)

        model.setLoginItemEnabled = { enabled = $0 }
        model.setLaunchesAtLogin(true)
        #expect(model.launchesAtLogin)
    }

    /// 换成更短的期限、马上会删掉条目时先等确认，取消就什么都不变。
    @Test func aShorterRetentionThatDeletesEntriesAsksFirst() throws {
        try store.insert(ClipContent(kind: .text, text: "十天前"), source: nil, at: Date().addingTimeInterval(-10 * 24 * 60 * 60))
        try store.insert(ClipContent(kind: .text, text: "刚才"), source: nil)
        var cleared = 0
        model.onRetentionChange = { cleared += 1 }

        model.chooseRetention(.week)
        #expect(model.pendingRetention == SettingsModel.PendingRetention(retention: .week, count: 1))
        #expect(settings.historyRetention == .never && cleared == 0)
        model.cancelRetention()
        #expect(model.pendingRetention == nil && settings.historyRetention == .never)

        model.chooseRetention(.week)
        model.confirmRetention()
        #expect(model.pendingRetention == nil)
        #expect(settings.historyRetention == .week && model.historyRetention == .week && cleared == 1)

        // 没有要删的条目时直接生效。
        model.chooseRetention(.year)
        #expect(model.pendingRetention == nil && settings.historyRetention == .year && cleared == 2)
    }

    @Test func clearingTheHistoryAsksFirstAndKeepsPinnedEntries() throws {
        try store.insert(ClipContent(kind: .text, text: "随手复制的"), source: nil)
        let kept = try store.insert(ClipContent(kind: .text, text: "固定的"), source: nil)
        try store.pin(kept, to: try store.createPinboard(name: "工作", color: .blue).id)

        model.requestClearHistory()
        #expect(model.pendingClear == 1)
        model.cancelClearHistory()
        #expect(try store.items(matching: ClipQuery(limit: 10)).count == 2)

        model.requestClearHistory()
        model.confirmClearHistory()
        #expect(model.pendingClear == nil)
        #expect(try store.items(matching: ClipQuery(limit: 10)).map(\.preview) == ["固定的"])
    }

    /// 参照 Alcove 的设置窗口，大小固定：不能拉伸，换页时窗口也不跟着内容变大变小。
    @Test func theWindowHasAFixedSize() {
        let window = SettingsWindow(model: model).makeWindow()
        #expect(!window.styleMask.contains(.resizable))
        model.reload()
        for page in SettingsModel.Page.allCases {
            model.page = page
            // SwiftUI 在下一轮 run loop 才按新内容改窗口大小。
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.layoutIfNeeded()
            #expect(window.contentView?.frame.size == SettingsWindow.size, "\(page)")
        }
    }
}
