import Testing
@testable import PasteMeCore

/// 发布版和开发版（ADR 0009）：只有发布版的应用读写用户自己的设置、历史和缓存。
@Suite struct AppVariantTests {
    @Test func onlyTheReleaseBundleIDIsTheRelease() {
        #expect(AppVariant(bundleID: "io.github.skjz.PasteMe") == .release)
        #expect(AppVariant(bundleID: "io.github.skjz.PasteMe.dev") == .development)
        // `swift run`、基准和截图模式直接运行二进制，没有 bundle id。
        #expect(AppVariant(bundleID: nil) == .development)
        #expect(AppVariant(bundleID: "com.apple.dt.xctest.tool") == .development)
    }

    @Test func testsRunAsDevelopment() {
        #expect(AppVariant.current == .development)
    }

    @Test func releaseAndDevelopmentUseSeparateFolders() {
        #expect(AppVariant.release.folderName == "PasteMe")
        #expect(AppVariant.development.folderName == "PasteMe Dev")
    }

    /// 应用包里用 `.standard`（它就是自己 bundle id 的域），没有对应 bundle id 时用开发版的 suite。
    @Test func onlyTheReleaseAppReadsTheUsersSettings() {
        func domain(_ bundleID: String?) -> String {
            let domain = Settings.sharedDomain(bundleID: bundleID)
            return domain.isStandard ? "standard:\(domain.name)" : "suite:\(domain.name)"
        }
        #expect(domain("io.github.skjz.PasteMe") == "standard:io.github.skjz.PasteMe")
        #expect(domain("io.github.skjz.PasteMe.dev") == "standard:io.github.skjz.PasteMe.dev")
        #expect(domain(nil) == "suite:io.github.skjz.PasteMe.dev")
        #expect(domain("com.apple.dt.xctest.tool") == "suite:io.github.skjz.PasteMe.dev")
    }
}
