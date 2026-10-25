import CryptoKit
import Foundation

/// 发布的版本号，按 SemVer 的 `主.次.修订` 比较。tag 前面的 `v` 去掉；带 `-beta` 这类预发布标记的不认，不推给用户。
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ string: String) {
        var text = Substring(string.trimmingCharacters(in: .whitespaces))
        if text.first == "v" { text = text.dropFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        self.parts = parts.map { $0! } + Array(repeating: 0, count: 3 - parts.count)
    }

    /// 正在运行的应用的版本（`CFBundleShortVersionString`）。`swift run` 和测试进程没有，为 nil。
    public static var current: AppVersion? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { lhs.parts == rhs.parts }
}

/// GitHub 上最新的一次发布：版本、发布说明、DMG 和它的签名（`scripts/update-signing.swift` 生成的 `.dmg.sig`）。
/// 缺了 DMG 或签名的发布（0.1.0 发布时还没有签名）照样告诉用户，只是不能自动安装，要去发布页下载。
public struct UpdateRelease: Equatable, Sendable {
    public let version: AppVersion
    /// 发布说明的 Markdown。
    public let notes: String
    /// 发布页，自动安装不了时让用户去这里下载。
    public let page: URL
    public let dmg: URL?
    public let signature: URL?

    public init(version: AppVersion, notes: String, page: URL, dmg: URL?, signature: URL?) {
        self.version = version
        self.notes = notes
        self.page = page
        self.dmg = dmg
        self.signature = signature
    }

    /// DMG 和签名都有，能下载下来验证、自动安装。
    public var canInstall: Bool { dmg != nil && signature != nil }

    /// 要不要告诉用户这次发布：比正在运行的版本新，自动检查时还要不是用户跳过的版本。
    public func isWorthOffering(current: AppVersion, skipped: String?, manual: Bool) -> Bool {
        guard version > current else { return false }
        return manual || skipped.flatMap(AppVersion.init) != version
    }

    /// 读 `GET /repos/{owner}/{repo}/releases/latest` 的回复。草稿、预发布、版本号认不出来的返回 nil。
    /// 资源按名字找 `PasteMe-<版本>.dmg` 和 `PasteMe-<版本>.dmg.sig`，名字里的版本和 tag 对不上的不算。
    public static func parse(latestRelease data: Data) -> UpdateRelease? {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        struct Release: Decodable {
            let tag_name: String
            let html_url: URL
            let body: String?
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              release.draft != true, release.prerelease != true,
              let version = AppVersion(release.tag_name)
        else { return nil }
        let dmgName = "PasteMe-\(version).dmg"
        func asset(_ name: String) -> URL? { release.assets.first { $0.name == name }?.browser_download_url }
        return UpdateRelease(
            version: version, notes: release.body ?? "", page: release.html_url,
            dmg: asset(dmgName), signature: asset(dmgName + ".sig")
        )
    }
}

/// 更新包的签名（ADR 0010）：发布者用只在自己钥匙串里的 Ed25519 私钥给 DMG 签名，应用用编进来的公钥验证，
/// 验证不过就不安装。发布版用的是临时签名，系统认不出发布者，只有这一道能挡住换了内容的 DMG。
public enum UpdateSignature {
    /// `swift scripts/update-signing.swift public-key` 打印的公钥。换钥匙等于让已经装好的版本收不到自动更新。
    public static let publicKey = Data(base64Encoded: "HQ9qkctnmqdNl3NA2m+RUImZpWDb0xKEfr+vY2Ae04E=")!

    /// `signature` 是 `.sig` 文件的内容：64 字节签名的 Base64。
    public static func isValid(_ signature: Data, for data: Data, publicKey: Data = publicKey) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              let text = String(data: signature, encoding: .utf8),
              let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return key.isValidSignature(raw, for: data)
    }
}

/// 自动检查的间隔：上次检查过了一天才再查。
public enum UpdateSchedule {
    public static let interval: TimeInterval = 24 * 60 * 60

    public static func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        // 时钟往回调过时也查一次，不要等到时钟追上来。
        return now.timeIntervalSince(lastCheck) >= interval || now < lastCheck
    }
}

public enum UpdateError: Error, Equatable, CustomStringConvertible {
    case badResponse(Int)
    case badSignature
    /// DMG 里没有 PasteMe.app，或者它不是发布版、版本和发布的不一样。
    case unexpectedApp(String)
    case commandFailed(String)

    public var description: String {
        switch self {
        case .badResponse(let status): "GitHub 返回了 \(status)"
        case .badSignature: "下载的安装包签名不对，没有安装"
        case .unexpectedApp(let reason): "安装包里的应用不对：\(reason)"
        case .commandFailed(let command): "\(command) 运行失败"
        }
    }
}

/// 向 GitHub 查最新的发布、下载 DMG 并验证签名。不带 Cookie、不缓存，请求里除了网址没有别的内容。
public struct UpdateClient: Sendable {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/Skjz/pasteMe/releases/latest")!

    private let session: URLSession
    private let latestURL: URL
    private let publicKey: Data

    public init(
        configuration: URLSessionConfiguration = UpdateClient.defaultConfiguration(),
        latestURL: URL = UpdateClient.latestReleaseURL,
        publicKey: Data = UpdateSignature.publicKey
    ) {
        session = URLSession(configuration: configuration)
        self.latestURL = latestURL
        self.publicKey = publicKey
    }

    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        return configuration
    }

    /// 最新的发布；没有发布过（404）或者读不出来时为 nil。
    public func latest() async throws -> UpdateRelease? {
        var request = URLRequest(url: latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw UpdateError.badResponse(status) }
        return UpdateRelease.parse(latestRelease: data)
    }

    /// 下载 DMG 和签名，验证通过后把 DMG 写进 `directory`，返回它的位置。
    /// DMG 每读到 64 KB 调用一次 `progress`（已经读到的字节数、响应头里的总大小，没有时为 nil），读完再调用一次。
    /// 外面的 Task 取消时停下，抛出 `CancellationError`。
    public func download(
        _ release: UpdateRelease,
        into directory: URL,
        progress: @escaping @Sendable (_ received: Int64, _ total: Int64?) -> Void = { _, _ in }
    ) async throws -> URL {
        guard let dmgURL = release.dmg, let signatureURL = release.signature else { throw UpdateError.badSignature }
        async let dmg = fetchReportingProgress(dmgURL, progress: progress)
        async let signature = fetch(signatureURL)
        let (dmgData, signatureData) = try await (dmg, signature)
        guard UpdateSignature.isValid(signatureData, for: dmgData, publicKey: publicKey) else { throw UpdateError.badSignature }
        let file = directory.appendingPathComponent("PasteMe-\(release.version).dmg")
        try dmgData.write(to: file)
        return file
    }

    /// 安装包大小的上限，超过的不是 PasteMe（现在的 DMG 约 4 MB）。
    static let maximumDMGSize: Int64 = 200 * 1024 * 1024

    private func fetchReportingProgress(_ url: URL, progress: @Sendable (Int64, Int64?) -> Void) async throws -> Data {
        let (bytes, response) = try await session.bytes(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.badResponse(status) }
        let total = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        var data = Data()
        data.reserveCapacity(Int(min(total ?? 0, Self.maximumDMGSize)))
        let step = 64 * 1024
        progress(0, total)
        for try await byte in bytes {
            data.append(byte)
            if data.count % step == 0 {
                try Task.checkCancellation()
                guard data.count <= Self.maximumDMGSize else { throw UpdateError.unexpectedApp("安装包超过 200 MB") }
                progress(Int64(data.count), total)
            }
        }
        try Task.checkCancellation()
        progress(Int64(data.count), total)
        return data
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.badResponse(status) }
        return data
    }
}

/// 把验证过的 DMG 里的 PasteMe.app 换到正在运行的应用的位置。
///
/// 先把新应用拷到和旧应用同一个卷上的临时目录里检查（bundle id 是发布版、版本和发布的一样、`codesign --verify` 通过），
/// 再用 `replaceItemAt` 一步换掉，换到一半失败时旧应用还在。运行中的应用可以被换掉：已经载入的代码不受影响，重启后才用新的。
public struct UpdateInstaller: Sendable {
    /// 要换掉的应用，生产中是 `Bundle.main.bundleURL`。
    public let app: URL

    public init(app: URL) {
        self.app = app
    }

    /// 这里不能自动安装的原因，能安装时为 nil。界面这时改为打开发布页。
    public var unavailableReason: String? {
        let path = app.path
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return "PasteMe 不是从「应用程序」文件夹打开的"
        }
        if !FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) {
            return "没有权限替换 \(app.deletingLastPathComponent().path) 里的 PasteMe"
        }
        return nil
    }

    /// 从 DMG 里取出应用、检查，再换掉 `app`。
    public func install(dmg: URL, expecting version: AppVersion, bundleID: String = AppVariant.releaseBundleID) throws {
        let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let mount = staging.appendingPathComponent("mount")
        try Self.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        let staged = staging.appendingPathComponent(app.lastPathComponent)
        do {
            defer { try? Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
            let source = mount.appendingPathComponent("PasteMe.app")
            guard FileManager.default.fileExists(atPath: source.path) else { throw UpdateError.unexpectedApp("找不到 PasteMe.app") }
            try Self.run("/usr/bin/ditto", [source.path, staged.path])
        }
        try Self.check(staged, version: version, bundleID: bundleID)
        _ = try FileManager.default.replaceItemAt(app, withItemAt: staged)
    }

    static func check(_ app: URL, version: AppVersion, bundleID: String) throws {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == bundleID else { throw UpdateError.unexpectedApp("bundle id 不是 \(bundleID)") }
        guard (info?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) == version else {
            throw UpdateError.unexpectedApp("版本不是 \(version)")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.commandFailed(([URL(fileURLWithPath: tool).lastPathComponent] + arguments.prefix(1)).joined(separator: " "))
        }
        return String(decoding: data, as: UTF8.self)
    }
}
