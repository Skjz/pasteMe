import Foundation
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
