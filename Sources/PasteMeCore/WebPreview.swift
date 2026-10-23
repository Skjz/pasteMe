import Foundation

/// 空格预览链接时在预览窗口里显示网页（#52）。这和复制时在后台获取链接预览（`LinkPreviewPolicy`）不一样：
/// 这里是用户自己按了空格，所以不看「链接预览」设置是哪一档，本机和内网的地址也加载；
/// 只有看起来像一次性的链接要用户再点一下，免得看一眼就让它失效。
public enum WebPreviewPolicy {
    public enum Start: Equatable, Sendable {
        /// 直接加载这个网址。
        case load(URL)
        /// 像一次性的链接：先说明，用户点了「加载网页」才加载。
        case askFirst(URL)
    }

    /// 网页里的一次跳转怎么处理。
    public enum Navigation: Equatable, Sendable {
        /// 在预览里继续：页面打开时的重定向、页面里的框架。
        case allow
        /// 交给默认浏览器（或者网址对应的应用）打开，预览里的页面不变。
        case openOutside
        case cancel
    }

    /// 不是 http、https 的链接（mailto: 这类）不是网页，返回 nil，预览里照旧显示网址。网址先去掉跟踪参数。
    public static func start(for address: String) -> Start? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), isWeb(url), url.host() != nil else { return nil }
        let cleaned = LinkPreviewPolicy.withoutTracking(url)
        return LinkPreviewPolicy.looksSingleUse(cleaned) ? .askFirst(cleaned) : .load(cleaned)
    }

    /// - Parameters:
    ///   - userClicked: 用户点了网页里的链接（`WKNavigationType.linkActivated`）。
    ///   - opensNewWindow: 网页要开一个新窗口（`target="_blank"`、`window.open`）。
    public static func navigation(to url: URL?, userClicked: Bool, opensNewWindow: Bool) -> Navigation {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        // 网页自己的内容：空白页、内嵌的数据。脚本地址不交给别人打开。
        let inPage = ["about", "data", "blob"].contains(scheme)
        if scheme == "javascript" { return .cancel }
        if userClicked || opensNewWindow {
            return inPage ? .cancel : .openOutside
        }
        // 页面自己跳到 zoommtg:// 这类地址会打开别的应用，不放行。
        return isWeb(url) || inPage ? .allow : .cancel
    }

    private static func isWeb(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }
}
