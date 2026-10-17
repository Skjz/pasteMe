import Foundation

/// 只读 HTML 拿不到信息的网站：网页要靠脚本才出内容，或者直接拦下不像浏览器的请求。
/// 这些网站改用它们给别人嵌入内容用的 oEmbed 接口取标题，图标用固定的地址。
/// 以后遇到同样的网站，在这里加一项。
enum KnownSite: CaseIterable {
    /// 网页只给一个要执行脚本的空壳（标题只有「Reddit」），有的网络还会被整个拦下（403）。
    case reddit

    static func matching(_ url: URL) -> KnownSite? {
        guard let host = url.host()?.lowercased() else { return nil }
        return allCases.first { site in
            site.hosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }

    var hosts: [String] {
        switch self {
        case .reddit: ["reddit.com", "redd.it"]
        }
    }

    /// 网站图标（大尺寸的 PNG）。
    var iconURL: URL {
        switch self {
        case .reddit: URL(string: "https://www.redditstatic.com/shreddit/assets/favicon/192x192.png")!
        }
    }

    /// 取这个网址的标题用的 oEmbed 接口。这个网址不支持时为 nil（Reddit 只支持帖子）。
    func oEmbedURL(for url: URL) -> URL? {
        switch self {
        case .reddit:
            guard url.path.contains("/comments/") else { return nil }
            var components = URLComponents(string: "https://www.reddit.com/oembed")!
            components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
            return components.url
        }
    }

    /// 接口不支持、或者没取到标题时，从网址本身读出的名字，例如 `r/swift`。
    func fallbackTitle(for url: URL) -> String? {
        switch self {
        case .reddit:
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count >= 2, ["r", "u", "user"].contains(parts[0].lowercased()) else { return nil }
            return (parts[0].lowercased() == "r" ? "r/" : "u/") + parts[1]
        }
    }
}
