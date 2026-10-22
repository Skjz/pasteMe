import Foundation
import Testing
@testable import PasteMeCore

@Suite final class SettingsTests {
    let suiteName = "PasteMeTests.Settings.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func showDuringScreenSharingIsOffByDefault() {
        #expect(Settings(defaults: defaults).showDuringScreenSharing == false)
    }

    @Test func showDuringScreenSharingPersists() {
        Settings(defaults: defaults).showDuringScreenSharing = true
        // 新建一个实例，模拟重启应用后再读取。
        #expect(Settings(defaults: defaults).showDuringScreenSharing == true)

        Settings(defaults: defaults).showDuringScreenSharing = false
        #expect(Settings(defaults: defaults).showDuringScreenSharing == false)
    }

    @Test func cursorStyleIsBreatheByDefault() {
        #expect(Settings(defaults: defaults).cursorStyle == .breathe)
    }

    @Test func cursorStylePersists() {
        Settings(defaults: defaults).cursorStyle = .flow
        #expect(Settings(defaults: defaults).cursorStyle == .flow)

        Settings(defaults: defaults).cursorStyle = .breathe
        #expect(Settings(defaults: defaults).cursorStyle == .breathe)
    }

    @Test func unknownCursorStyleFallsBackToBreathe() {
        // 例如以前的版本存过、现在已经删掉的样式。
        defaults.set("plain", forKey: "cursorStyle")
        #expect(Settings(defaults: defaults).cursorStyle == .breathe)
    }

    @Test func appAliasesAreEmptyByDefault() {
        #expect(Settings(defaults: defaults).appAliases.isEmpty)
    }

    @Test func appAliasesPersistPerAppAndDropEmptyOnes() {
        let settings = Settings(defaults: defaults)
        settings.setAliases(["wx", " 绿泡泡 ", "", "WX"], for: "com.tencent.xinWeChat")
        settings.setAliases(["finder"], for: "com.apple.finder")

        #expect(Settings(defaults: defaults).appAliases == [
            "com.tencent.xinWeChat": ["wx", "绿泡泡"],
            "com.apple.finder": ["finder"],
        ])

        settings.setAliases([], for: "com.apple.finder")
        #expect(Settings(defaults: defaults).appAliases == ["com.tencent.xinWeChat": ["wx", "绿泡泡"]])
    }

    @Test func imagesAsFilesAndLinkPreviewsAreOffByDefault() {
        let settings = Settings(defaults: defaults)
        #expect(!settings.pasteImagesAsFiles)
        #expect(settings.linkPreviewMode == .off)
        #expect(settings.lastPinboardID == nil)
    }

    @Test func newSwitchesPersist() {
        Settings(defaults: defaults).pasteImagesAsFiles = true
        Settings(defaults: defaults).linkPreviewMode = .siteIcon
        Settings(defaults: defaults).lastPinboardID = 3
        #expect(Settings(defaults: defaults).pasteImagesAsFiles)
        #expect(Settings(defaults: defaults).linkPreviewMode == .siteIcon)
        #expect(Settings(defaults: defaults).lastPinboardID == 3)

        Settings(defaults: defaults).lastPinboardID = nil
        #expect(Settings(defaults: defaults).lastPinboardID == nil)
    }

    @Test func unknownLinkPreviewModeFallsBackToOff() {
        defaults.set("everything", forKey: "linkPreviewMode")
        #expect(Settings(defaults: defaults).linkPreviewMode == .off)
    }

    @Test func historyIsNeverClearedByDefault() {
        #expect(Settings(defaults: defaults).historyRetention == .never)
        defaults.set("forever", forKey: "historyRetention")
        #expect(Settings(defaults: defaults).historyRetention == .never)
    }

    @Test func recordSoundIsOffByDefault() {
        #expect(Settings(defaults: defaults).playsSoundOnRecord == false)
    }

    @Test func recordSoundPersists() {
        Settings(defaults: defaults).playsSoundOnRecord = true
        #expect(Settings(defaults: defaults).playsSoundOnRecord == true)

        Settings(defaults: defaults).playsSoundOnRecord = false
        #expect(Settings(defaults: defaults).playsSoundOnRecord == false)
    }

    @Test func historyRetentionPersists() {
        Settings(defaults: defaults).historyRetention = .week
        #expect(Settings(defaults: defaults).historyRetention == .week)
        Settings(defaults: defaults).historyRetention = .never
        #expect(Settings(defaults: defaults).historyRetention == .never)
    }
}
