import Foundation

/// 链接的网页标题、预览图和网站图标（#11）。
public struct LinkPreview: Sendable, Equatable {
    /// 网页标题。获取失败、网页没有标题、或者只取了网站图标时为空字符串。
    public var title: String
    /// 预览图的缩略图（PNG），存在条目的 `thumbnail` 里。
    public var image: Data?
    /// 网站图标（PNG，最大 128 像素）。
    public var icon: Data?

    public init(title: String, image: Data? = nil, icon: Data? = nil) {
        self.title = title
        self.image = image
        self.icon = icon
    }

    /// 获取失败。存下它之后，这个条目不再获取。
    public static let failed = LinkPreview(title: "")
}

/// 设置里的「链接预览」。
public enum LinkPreviewMode: String, CaseIterable, Sendable {
    /// 不发任何请求。
    case off
    /// 只请求网站首页，取网站图标。复制的网址本身不打开，不会让任何链接失效。
    case siteIcon
    /// 打开复制的网址，取网页标题、预览图和网站图标；看起来像一次性的链接退回 `siteIcon`。
    case full
}

/// 要去获取什么：`url` 是实际请求的网址。
public struct LinkPreviewRequest: Sendable, Equatable {
    public var url: URL
    /// true：`url` 就是复制的网址，取网页标题和预览图；false：`url` 是网站首页，只取网站图标。
    public var includesPage: Bool

    public init(url: URL, includesPage: Bool) {
        self.url = url
        self.includesPage = includesPage
    }
}

/// 向网站获取链接预览。
public protocol LinkPreviewFetching: Sendable {
    /// 失败或超时时返回 nil。在后台执行。
    func fetchPreview(_ request: LinkPreviewRequest) async -> LinkPreview?
}

/// 哪些链接可以去请求、请求哪个网址。获取会向对方网站发请求：本机和内网的地址不发；
/// 看起来像一次性的链接（登录、重置密码、验证邮箱……）只请求网站首页，不打开它本身。
public enum LinkPreviewPolicy {
    /// 按设置决定请求什么。不能请求时（关闭、本机或内网地址）返回 nil。跟踪参数先去掉（`withoutTracking`）。
    public static func request(for url: URL, mode: LinkPreviewMode) -> LinkPreviewRequest? {
        let url = withoutTracking(url)
        guard mode != .off, allowsFetching(url), let home = homepage(of: url) else { return nil }
        if mode == .full, !looksSingleUse(url) {
            return LinkPreviewRequest(url: url, includesPage: true)
        }
        return LinkPreviewRequest(url: home, includesPage: false)
    }

    /// 去掉分享时附带的跟踪参数（`utm_` 开头的、YouTube 和 Spotify 的 `si`、Reddit 的 `share_id` 等）。
    /// 它们只是标出谁分享的，打开的是同一个网页；而且一长串随机字符会被当成令牌（`looksSingleUse`）。
    public static func withoutTracking(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty
        else { return url }
        let kept = items.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !trackingParameters.contains(name)
        }
        guard kept.count != items.count else { return url }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }

    static let trackingParameters: Set<String> = [
        "si", "share_id", "fbclid", "gclid", "dclid", "msclkid", "igshid", "igsh", "mc_cid", "mc_eid",
        "spm", "ref_src", "ref_url", "_hsenc", "_hsmi", "mkt_tok", "yclid", "twclid", "ttclid", "wt.mc_id",
    ]

    /// 网站首页：只留协议、主机和端口。
    public static func homepage(of url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }

    public static func allowsFetching(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host()?.lowercased(), !host.isEmpty
        else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.contains(":") { return false } // IPv6 地址：不区分公网和内网，一律不发
        if let octets = ipv4Octets(host) { return !isPrivate(octets) }
        // 没有点的主机名（http://nas/）只在内网里解析得到。
        guard host.contains(".") else { return false }
        let localSuffixes = [".local", ".localhost", ".internal", ".intranet", ".lan", ".home", ".home.arpa", ".corp"]
        return !localSuffixes.contains { host.hasSuffix($0) }
    }

    /// 网址看起来像一次性的：路径里有登录、重置密码、验证这类词，参数名像令牌，或者带着一长串随机字符
    /// （令牌、签名、UUID）。宁可多认：认错了只是少了网页标题，漏认了链接可能失效。
    /// 很短、又没有这些特征的令牌（`https://x.co/r/k9Qz`）认不出来。
    public static func looksSingleUse(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return true }
        let path = components.percentEncodedPath.removingPercentEncoding ?? components.percentEncodedPath
        let pathWords = words(in: path.lowercased())
        if pathWords.contains(where: singleUsePathWords.contains) { return true }
        for item in components.queryItems ?? [] {
            let nameWords = words(in: item.name.lowercased())
            if nameWords.contains(where: singleUseParameterWords.contains) { return true }
            if let value = item.value, looksRandom(value) { return true }
        }
        if looksRandom(path) { return true }
        // 有的网站把令牌放在 # 后面（OAuth 的 implicit flow）。
        if let fragment = components.fragment, fragment.contains("="), looksRandom(fragment) || fragment.lowercased().contains("token") {
            return true
        }
        return false
    }

    /// 出现在路径里就当作一次性链接的词。
    static let singleUsePathWords: Set<String> = [
        "reset", "verify", "verification", "confirm", "confirmation", "activate", "activation",
        "invite", "invitation", "unsubscribe", "optout", "magic", "magiclink", "login", "signin",
        "auth", "oauth", "authorize", "callback", "sso", "saml", "password", "passwordless", "otp",
        "token", "approve", "accept", "claim", "redeem", "download",
    ]

    /// 作为参数名（或参数名里的一个词）就当作一次性链接的词。
    static let singleUseParameterWords: Set<String> = [
        "token", "code", "key", "apikey", "sig", "signature", "otp", "auth", "hash", "ticket",
        "nonce", "state", "session", "sid", "secret", "password", "reset", "verify", "confirm",
        "invite", "magic", "jwt", "credential", "credentials", "expires", "signed",
    ]

    /// 按非字母数字的字符切开。
    private static func words(in text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// 有一段像随机生成的字符：UUID，或者 16 个以上连续的字母数字、字母和数字都有。
    private static func looksRandom(_ text: String) -> Bool {
        if text.range(of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", options: .regularExpression) != nil {
            return true
        }
        let runs = text.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        return runs.contains { run in
            run.count >= 16 && run.contains(where: \.isNumber) && run.contains(where: \.isLetter)
        }
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy((0...255).contains) else { return nil }
        return octets
    }

    /// 本机、私有网段、链路本地和运营商级 NAT（100.64.0.0/10，Tailscale 等也用它）。
    private static func isPrivate(_ o: [Int]) -> Bool {
        switch (o[0], o[1]) {
        case (0, _), (10, _), (127, _): true
        case (169, 254), (192, 168): true
        case (172, 16...31): true
        case (100, 64...127): true
        default: false
        }
    }
}
