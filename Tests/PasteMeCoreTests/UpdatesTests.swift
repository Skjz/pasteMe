import CryptoKit
import Foundation
import Testing
@testable import PasteMeCore

/// 检查更新（ADR 0010）：版本号怎么比、GitHub 的回复怎么读、签名不对时不安装、DMG 里的应用怎么换进来。
@Suite(.serialized) struct UpdatesTests {
    @Test func versionsCompareByNumbersNotText() throws {
        let v = { (text: String) in try #require(AppVersion(text)) }
        #expect(try v("v0.10.0") > v("0.9.3"))
        #expect(try v("1.0") == v("1.0.0"))
        #expect(try v("0.2.0") > v("0.1.9"))
        #expect(try v("v0.2.0").description == "0.2.0")
        for bad in ["", "v", "0.2.0-beta", "1.2.3.4", "1..2", "-1.0"] {
            #expect(AppVersion(bad) == nil, "\(bad)")
        }
    }

    @Test func latestReleaseNeedsTheDMGAndItsSignature() throws {
        let release = try #require(UpdateRelease.parse(latestRelease: Self.releaseJSON(tag: "v0.2.0")))
        #expect(release.version == AppVersion("0.2.0"))
        #expect(release.notes == "新的文件卡片")
        #expect(release.page.absoluteString == "https://github.com/Skjz/pasteMe/releases/tag/v0.2.0")
        #expect(release.dmg?.absoluteString == "https://updates.test/PasteMe-0.2.0.dmg")
        #expect(release.signature?.absoluteString == "https://updates.test/PasteMe-0.2.0.dmg.sig")
        #expect(release.canInstall)

        // 0.1.0 发布时还没有签名：照样告诉用户，但只能去发布页下载。
        let unsigned = try #require(UpdateRelease.parse(latestRelease: Self.releaseJSON(tag: "v0.2.0", assets: ["PasteMe-0.2.0.dmg"])))
        #expect(!unsigned.canInstall)
        // 资源的版本和 tag 对不上也不能安装。
        #expect(UpdateRelease.parse(latestRelease: Self.releaseJSON(tag: "v0.3.0"))?.canInstall == false)
        #expect(UpdateRelease.parse(latestRelease: Self.releaseJSON(tag: "v0.2.0", prerelease: true)) == nil)
        #expect(UpdateRelease.parse(latestRelease: Self.releaseJSON(tag: "nightly")) == nil)
        #expect(UpdateRelease.parse(latestRelease: Data("not json".utf8)) == nil)
    }

    @Test func onlyTheReleaseKeyCanSignAnUpdate() throws {
        let key = Curve25519.Signing.PrivateKey()
        let dmg = Data("dmg".utf8)
        let signature = try Self.sign(dmg, with: key)

        #expect(UpdateSignature.isValid(signature, for: dmg, publicKey: key.publicKey.rawRepresentation))
        #expect(!UpdateSignature.isValid(signature, for: Data("dmG".utf8), publicKey: key.publicKey.rawRepresentation))
        #expect(!UpdateSignature.isValid(signature, for: dmg, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
        #expect(!UpdateSignature.isValid(Data("garbage".utf8), for: dmg, publicKey: key.publicKey.rawRepresentation))
        // 编进应用的公钥要能用。
        #expect((try? Curve25519.Signing.PublicKey(rawRepresentation: UpdateSignature.publicKey)) != nil)
    }

    @Test func skippedVersionsAreOfferedOnlyWhenAsked() throws {
        let release = try #require(UpdateRelease.parse(latestRelease: Self.releaseJSON(tag: "v0.2.0")))
        let current = try #require(AppVersion("0.1.0"))
        #expect(release.isWorthOffering(current: current, skipped: nil, manual: false))
        #expect(!release.isWorthOffering(current: current, skipped: "0.2.0", manual: false))
        #expect(release.isWorthOffering(current: current, skipped: "0.2.0", manual: true))
        // 跳过的是更早的版本，新的照样提示。
        #expect(release.isWorthOffering(current: current, skipped: "0.1.5", manual: false))
        #expect(!release.isWorthOffering(current: try #require(AppVersion("0.2.0")), skipped: nil, manual: true))
        #expect(!release.isWorthOffering(current: try #require(AppVersion("0.3.0")), skipped: nil, manual: true))
    }

    @Test func checksAgainAfterADay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UpdateSchedule.isDue(lastCheck: nil, now: now))
        #expect(!UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-23 * 60 * 60), now: now))
        #expect(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-24 * 60 * 60), now: now))
        #expect(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(60 * 60), now: now))
    }

    @Test func clientReadsTheLatestReleaseWithoutCookies() async throws {
        let latest = "https://updates.test/latest-\(UUID().uuidString)"
        StubURLProtocol.set(.data(Self.releaseJSON(tag: "v0.2.0"), contentType: "application/json"), for: latest)
        let client = UpdateClient(configuration: StubURLProtocol.configuration(), latestURL: URL(string: latest)!)

        #expect(try await client.latest()?.version == AppVersion("0.2.0"))
        let request = try #require(StubURLProtocol.requests(host: "updates.test").last { $0.url?.absoluteString == latest })
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")

        let none = "https://updates.test/none-\(UUID().uuidString)"
        StubURLProtocol.set(.status(404), for: none)
        #expect(try await UpdateClient(configuration: StubURLProtocol.configuration(), latestURL: URL(string: none)!).latest() == nil)

        let limited = "https://updates.test/limited-\(UUID().uuidString)"
        StubURLProtocol.set(.status(403), for: limited)
        await #expect(throws: UpdateError.badResponse(403)) {
            try await UpdateClient(configuration: StubURLProtocol.configuration(), latestURL: URL(string: limited)!).latest()
        }
    }

    @Test func downloadKeepsOnlySignedDMGs() async throws {
        let directory = try ClipStoreTests.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Curve25519.Signing.PrivateKey()
        let id = UUID().uuidString
        let release = UpdateRelease(
            version: AppVersion("0.2.0")!, notes: "", page: URL(string: "https://updates.test/page")!,
            dmg: URL(string: "https://updates.test/\(id).dmg")!, signature: URL(string: "https://updates.test/\(id).dmg.sig")!
        )
        let dmg = Data("the real dmg".utf8)
        StubURLProtocol.set(.data(dmg, contentType: "application/octet-stream"), for: release.dmg!.absoluteString)
        StubURLProtocol.set(.data(try Self.sign(dmg, with: key), contentType: "text/plain"), for: release.signature!.absoluteString)
        let client = UpdateClient(configuration: StubURLProtocol.configuration(), publicKey: key.publicKey.rawRepresentation)

        let file = try await client.download(release, into: directory)
        #expect(FileManager.default.contents(atPath: file.path) == dmg)

        // 换了内容的 DMG，签名还是原来那个。
        try FileManager.default.removeItem(at: file)
        StubURLProtocol.set(.data(Data("a different dmg".utf8), contentType: "application/octet-stream"), for: release.dmg!.absoluteString)
        await #expect(throws: UpdateError.badSignature) { try await client.download(release, into: directory) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func downloadReportsProgressAndCanBeCancelled() async throws {
        let directory = try ClipStoreTests.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Curve25519.Signing.PrivateKey()
        let id = UUID().uuidString
        let release = UpdateRelease(
            version: AppVersion("0.2.0")!, notes: "", page: URL(string: "https://updates.test/page")!,
            dmg: URL(string: "https://updates.test/\(id).dmg")!, signature: URL(string: "https://updates.test/\(id).dmg.sig")!
        )
        let dmg = Data(repeating: 7, count: 200 * 1024)
        StubURLProtocol.set(.data(dmg, contentType: "application/octet-stream"), for: release.dmg!.absoluteString)
        StubURLProtocol.set(.data(try Self.sign(dmg, with: key), contentType: "text/plain"), for: release.signature!.absoluteString)
        let client = UpdateClient(configuration: StubURLProtocol.configuration(), publicKey: key.publicKey.rawRepresentation)

        let reports = Reports()
        _ = try await client.download(release, into: directory) { received, _ in reports.add(received) }
        let received = reports.all
        #expect(received.first == 0 && received.last == Int64(dmg.count))
        #expect(received.contains(64 * 1024) && received == received.sorted())

        // 读到一半，用户在窗口里点了取消（取消的是外面的 Task）：不写盘。
        try FileManager.default.removeItem(at: directory.appendingPathComponent("PasteMe-0.2.0.dmg"))
        let outer = Outer()
        let task = Task {
            try await client.download(release, into: directory) { received, _ in
                if received >= 64 * 1024 { outer.task?.cancel() }
            }
        }
        outer.task = task
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("PasteMe-0.2.0.dmg").path))
    }

    final class Outer: @unchecked Sendable {
        var task: Task<URL, Error>?
    }

    final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int64] = []
        func add(_ value: Int64) { lock.withLock { values.append(value) } }
        var all: [Int64] { lock.withLock { values } }
    }

    @Test func installerReplacesTheAppWithTheOneInTheDMG() throws {
        let directory = try ClipStoreTests.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let installed = directory.appendingPathComponent("Applications/PasteMe.app")
        try Self.makeApp(at: installed, version: "0.1.0")
        let dmg = try Self.makeDMG(in: directory, version: "0.2.0")
        let installer = UpdateInstaller(app: installed)
        #expect(installer.unavailableReason == nil)

        // 发布说的是 0.3.0，DMG 里却是 0.2.0（拿旧版本的签名包冒充新版本）：不换。
        #expect(throws: UpdateError.unexpectedApp("版本不是 0.3.0")) {
            try installer.install(dmg: dmg, expecting: AppVersion("0.3.0")!)
        }
        #expect(Self.version(of: installed) == "0.1.0")
        // DMG 里是开发版也不换。
        let dev = directory.appendingPathComponent("dev/PasteMe.app")
        try Self.makeApp(at: dev, version: "0.2.0", bundleID: AppVariant.developmentBundleID)
        #expect(throws: UpdateError.unexpectedApp("bundle id 不是 io.github.skjz.PasteMe")) {
            try UpdateInstaller.check(dev, version: AppVersion("0.2.0")!, bundleID: AppVariant.releaseBundleID)
        }

        try installer.install(dmg: dmg, expecting: AppVersion("0.2.0")!)
        #expect(Self.version(of: installed) == "0.2.0")
        // 挂载的 DMG 已经推出。
        let mounted = try UpdateInstaller.run("/usr/bin/hdiutil", ["info"])
        #expect(!mounted.contains(directory.path))
    }

    @Test func appsOutsideApplicationsAreNotReplaced() {
        #expect(UpdateInstaller(app: URL(fileURLWithPath: "/Volumes/PasteMe 0.2.0/PasteMe.app")).unavailableReason != nil)
        let translocated = "/private/var/folders/x/AppTranslocation/1234/d/PasteMe.app"
        #expect(UpdateInstaller(app: URL(fileURLWithPath: translocated)).unavailableReason != nil)
        #expect(UpdateInstaller(app: URL(fileURLWithPath: "/System/Applications/PasteMe.app")).unavailableReason != nil)
    }

    // MARK: - 测试数据

    static func releaseJSON(tag: String, prerelease: Bool = false, assets: [String] = ["PasteMe-0.2.0.dmg", "PasteMe-0.2.0.dmg.sig"]) -> Data {
        let json: [String: Any] = [
            "tag_name": tag,
            "html_url": "https://github.com/Skjz/pasteMe/releases/tag/\(tag)",
            "body": "新的文件卡片",
            "draft": false,
            "prerelease": prerelease,
            "assets": assets.map { ["name": $0, "browser_download_url": "https://updates.test/\($0)"] },
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    static func sign(_ data: Data, with key: Curve25519.Signing.PrivateKey) throws -> Data {
        Data(try key.signature(for: data).base64EncodedString().utf8)
    }

    /// 一个能通过 `codesign --verify` 的最小应用：Info.plist 加一个临时签名的可执行文件。
    static func makeApp(at app: URL, version: String, bundleID: String = AppVariant.releaseBundleID) throws {
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("PasteMe").path)
        let info: NSDictionary = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "PasteMe",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
        ]
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try UpdateInstaller.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
    }

    static func makeDMG(in directory: URL, version: String) throws -> URL {
        let stage = directory.appendingPathComponent("stage")
        try makeApp(at: stage.appendingPathComponent("PasteMe.app"), version: version)
        let dmg = directory.appendingPathComponent("PasteMe-\(version).dmg")
        try UpdateInstaller.run("/usr/bin/hdiutil", ["create", "-volname", "PasteMe \(version)", "-srcfolder", stage.path, "-fs", "HFS+", "-format", "UDZO", "-ov", dmg.path])
        return dmg
    }

    static func version(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }
}
