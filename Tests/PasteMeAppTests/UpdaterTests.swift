import AppKit
import Foundation
import SwiftUI
import Testing
@testable import PasteMeApp
import PasteMeCore

/// 自动检查更新：什么时候真的去查、查到的新版本什么时候放进菜单。手动检查和安装要弹窗，不在这里测。
@MainActor
@Suite final class UpdaterTests {
    let suiteName = "PasteMeTests.Updater.\(UUID().uuidString)"
    let settings: PasteMeCore.Settings
    var requests = 0
    var reply: UpdateRelease? = UpdaterTests.release("0.2.0")

    init() throws {
        settings = PasteMeCore.Settings(defaults: try #require(UserDefaults(suiteName: suiteName)))
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func makeUpdater(variant: AppVariant = .release) -> Updater {
        Updater(settings: settings, toast: Toast(), current: AppVersion("0.1.0"), variant: variant) { [unowned self] in
            requests += 1
            return reply
        }
    }

    static func release(_ version: String, signed: Bool = true) -> UpdateRelease {
        let dmg = URL(string: "https://github.com/Skjz/pasteMe/releases/download/v\(version)/PasteMe-\(version).dmg")!
        return UpdateRelease(
            version: AppVersion(version)!, notes: "", page: URL(string: "https://github.com/Skjz/pasteMe/releases")!,
            dmg: dmg, signature: signed ? dmg.appendingPathExtension("sig") : nil
        )
    }

    @Test func aNewVersionGoesIntoTheMenuAndWaitsADay() async {
        let updater = makeUpdater()
        updater.checkIfDue()
        await updater.checking?.value
        #expect(requests == 1)
        #expect(updater.available?.version == AppVersion("0.2.0"))
        #expect(settings.lastUpdateCheck != nil)

        // 一天之内不再查。
        updater.checkIfDue()
        await updater.checking?.value
        #expect(requests == 1)
    }

    @Test func skippedAndOlderVersionsStayOutOfTheMenu() async {
        settings.skippedUpdateVersion = "0.2.0"
        let updater = makeUpdater()
        updater.checkIfDue()
        await updater.checking?.value
        #expect(requests == 1 && updater.available == nil)

        reply = Self.release("0.1.0")
        settings.lastUpdateCheck = nil
        updater.checkIfDue()
        await updater.checking?.value
        #expect(requests == 2 && updater.available == nil)
    }

    @Test func unsignedReleasesAreNotAnnounced() async {
        // 没有 .sig 的发布可能不是发布者传的：自动检查不提示、不放进菜单。
        reply = Self.release("0.2.0", signed: false)
        let updater = makeUpdater()
        updater.checkIfDue()
        await updater.checking?.value
        #expect(requests == 1 && updater.available == nil)
    }

    @Test func releaseNotesHaveNoLinks() throws {
        // 弹窗出现在验签之前，发布说明里的链接一点就会打开（file:// 也行）。
        let view = Updater.notesView("**新功能**：下载 [这个](file:///Applications/Calculator.app) 或 https://evil.test")
        let text = try #require((view as? NSScrollView)?.documentView as? NSTextView)
        let storage = try #require(text.textStorage)
        #expect(storage.string == "新功能：下载 这个 或 https://evil.test")
        var links = 0
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if value != nil { links += 1 }
        }
        #expect(links == 0)
    }

    static let steps: [Updater.InstallStep?] = [
        .downloading(received: 0, total: nil),
        .downloading(received: 1_200_000, total: 3_033_655),
        .checking,
        .installing,
    ]

    static func height(_ view: some View) -> CGFloat {
        NSHostingView(rootView: view).fittingSize.height
    }

    @Test func everyStepFitsTheWindowSizedForTheFirst() {
        // 窗口按第一步定下大小以后不再变（UpdateWindow），后面每一步都要一样高。
        let version = AppVersion("0.2.1")!
        let heights = Self.steps.map { Self.height(UpdateProgressContent(step: $0, version: version) {}) }
        #expect(Set(heights).count == 1, "\(heights)")
    }

    @Test func detailTextsAreNotCutOff() {
        // 在虚拟机里的 macOS 14 上看到过「完成后 PasteMe 会重新…」：说明比一行长，窗口又不长高。
        // 同一句话在 macOS 27 上排得下一行，在 14 上要两行，所以留两行、并检查每一句都不超过两行。
        func natural(_ text: String) -> CGFloat {
            Self.height(Text(text).font(.callout).frame(width: UpdateProgressContent.textWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true))
        }
        for step in Self.steps {
            let text = UpdateProgressContent.detailText(for: step)
            #expect(natural(text) <= Self.height(UpdateProgressContent.detail(text).frame(width: UpdateProgressContent.textWidth)), "\(text)")
        }
        // 量法本身认得出放不下的文字。
        let long = String(repeating: "检查安装包并替换应用，", count: 8)
        #expect(natural(long) > Self.height(UpdateProgressContent.detail(long).frame(width: UpdateProgressContent.textWidth)))
    }

    @Test func turnedOffOrDevelopmentBuildsNeverAsk() async {
        settings.checksForUpdates = false
        let updater = makeUpdater()
        updater.checkIfDue()
        await updater.checking?.value

        settings.checksForUpdates = true
        let development = makeUpdater(variant: .development)
        development.checkIfDue()
        await development.checking?.value

        #expect(requests == 0)
        #expect(settings.lastUpdateCheck == nil)
    }

    @Test func aFailedCheckTriesAgainNextTime() async {
        let updater = Updater(settings: settings, toast: Toast(), current: AppVersion("0.1.0"), variant: .release) {
            throw UpdateError.badResponse(403)
        }
        updater.checkIfDue()
        await updater.checking?.value
        #expect(settings.lastUpdateCheck == nil)
        #expect(updater.available == nil)
    }
}
