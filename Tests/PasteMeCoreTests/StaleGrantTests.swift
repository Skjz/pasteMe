import Foundation
import Testing
@testable import PasteMeCore

/// 启动时什么时候删掉失效的辅助功能条目（ADR 0011）：只在装好的那一份里、同一份签名只处理一次。
@Suite struct StaleGrantTests {
    static let installed = "/Applications/PasteMe.app"
    static let certificate = #"identifier "io.github.skjz.PasteMe" and certificate leaf = H"7122""#

    func situation(
        trusted: Bool = false,
        requirement: String? = Self.certificate,
        app: String = Self.installed,
        registered: String? = Self.installed,
        handled: String? = nil
    ) -> StaleGrant.Situation {
        StaleGrant.Situation(isTrusted: trusted, requirement: requirement, appPath: app, registeredPath: registered, handledRequirement: handled)
    }

    @Test func theInstalledCopyClearsItsStaleEntryOnce() {
        // 从临时签名的 0.1.0 换成证书签名的版本：没有授权，这份签名没处理过。
        #expect(StaleGrant.action(for: situation(handled: #"cdhash H"4a1e""#)) == .reset(Self.certificate))
        // 清理过了，用户在提示里拒绝了：下次启动不再删。
        #expect(StaleGrant.action(for: situation(handled: Self.certificate)) == .nothing)
    }

    @Test func trustedSignaturesAreRememberedSoATurnedOffSwitchStaysOff() {
        #expect(StaleGrant.action(for: situation(trusted: true)) == .remember(Self.certificate))
        #expect(StaleGrant.action(for: situation(trusted: true, handled: Self.certificate)) == .nothing)
        // 用户后来自己关掉了开关：签名没变，不重置。
        #expect(StaleGrant.action(for: situation(trusted: false, handled: Self.certificate)) == .nothing)
    }

    @Test func copiesOtherThanTheInstalledOneNeverClear() {
        // 发布前从挂载的 DMG 里试跑、用户在 DMG 里双击试用、被挪进 App Translocation、build/ 里打的包：
        // 删了会连「应用程序」里那份的授权一起删。
        for app in [
            "/Volumes/PasteMe 0.2.0/PasteMe.app",
            "/private/var/folders/x/AppTranslocation/1234/d/PasteMe.app",
            "/Users/someone/pasteMe/build/dmg/PasteMe.app",
        ] {
            #expect(StaleGrant.action(for: situation(app: app)) == .nothing, "\(app)")
        }
        // LaunchServices 登记的也正是这份副本时（比如只在 DMG 里打开过、还没拖进「应用程序」），路径相等，
        // 也要靠 /Volumes 和 App Translocation 的判断挡住。
        for app in ["/Volumes/PasteMe 0.2.0/PasteMe.app", "/private/var/folders/x/AppTranslocation/1234/d/PasteMe.app"] {
            #expect(StaleGrant.action(for: situation(app: app, registered: app)) == .nothing, "\(app)")
        }
        // 系统还没登记这个 bundle id（应用放在临时目录里），tccutil 也删不了。
        #expect(StaleGrant.action(for: situation(registered: nil)) == .nothing)
        #expect(StaleGrant.action(for: situation(requirement: nil)) == .nothing)
    }

    @Test func pathsAreComparedAfterResolvingSymlinks() throws {
        let directory = try ClipStoreTests.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("PasteMe.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        // 临时目录在 /var/folders 下，它是 /private/var 的符号链接。
        let viaVar = app.path.replacingOccurrences(of: "/private/var/", with: "/var/")
        let viaPrivate = viaVar.replacingOccurrences(of: "/var/", with: "/private/var/")
        #expect(StaleGrant.isInstalledCopy(viaVar, registered: viaPrivate + "/"))
        #expect(!StaleGrant.isInstalledCopy(viaVar, registered: directory.appendingPathComponent("Other.app").path))
    }
}
