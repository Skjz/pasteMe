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
}
