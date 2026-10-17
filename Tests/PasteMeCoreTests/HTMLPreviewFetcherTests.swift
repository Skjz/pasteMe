import Foundation
import Testing
@testable import PasteMeCore

/// 假的网络：按网址返回预设的响应，记下收到的请求。每个测试用自己的主机名，互不干扰。
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case page(String, contentType: String = "text/html; charset=utf-8")
        case data(Data, contentType: String)
        case redirect(String)
        case status(Int)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var received: [URLRequest] = []

    static func set(_ reply: Reply, for url: String) {
        lock.withLock { replies[url] = reply }
    }

    /// 发到这个主机的请求（网址）。
    static func requested(host: String) -> [String] {
        lock.withLock { received.filter { $0.url?.host() == host }.compactMap { $0.url?.absoluteString } }
    }

    static func requests(host: String) -> [URLRequest] {
        lock.withLock { received.filter { $0.url?.host() == host } }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = HTMLPreviewFetcher.defaultConfiguration()
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let reply = Self.lock.withLock {
            Self.received.append(request)
            return Self.replies[url.absoluteString]
        }
        func respond(_ status: Int, _ headers: [String: String], _ body: Data) {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        switch reply {
        case .page(let html, let type):
            respond(200, ["Content-Type": type], Data(html.utf8))
        case .data(let data, let type):
            respond(200, ["Content-Type": type], data)
        case .redirect(let location):
            let target = URL(string: location, relativeTo: url)!.absoluteURL
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .status(let code):
            respond(code, [:], Data())
        case nil:
            respond(404, [:], Data())
        }
    }

    override func stopLoading() {}
}

/// 只读 HTML 的链接预览：读出标题、预览图、图标；不带 Cookie；不跟去一次性网址和内网的重定向；
/// 不是网页的链接不下载；GBK 网页也能读出标题（#11）。
@Suite struct HTMLPreviewFetcherTests {
    let host = "t\(UUID().uuidString.prefix(8).lowercased()).example.com"
    let fetcher = HTMLPreviewFetcher(configuration: StubURLProtocol.configuration())
    let png = ClipStoreTests.makePNG(width: 8, height: 8)!

    private func url(_ path: String) -> String { "https://\(host)\(path)" }

    private func page(_ path: String) -> LinkPreviewRequest {
        LinkPreviewRequest(url: URL(string: url(path))!, includesPage: true)
    }

    @Test func readsTitleImageAndIconFromThePage() async throws {
        StubURLProtocol.set(.page("""
            <html><head>
            <title>备用标题</title>
            <meta property="og:title" content="Swift &amp; 你好">
            <meta property="og:image" content="/card.png">
            <link rel="icon" href="/favicon-16.png" sizes="16x16">
            <link rel="apple-touch-icon" href="/touch.png">
            </head><body><script>location.href='/danger'</script></body></html>
            """), for: url("/repo"))
        StubURLProtocol.set(.data(png, contentType: "image/png"), for: url("/card.png"))
        StubURLProtocol.set(.data(png, contentType: "image/png"), for: url("/touch.png"))

        let preview = try #require(await fetcher.fetchPreview(page("/repo")))

        #expect(preview.title == "Swift & 你好")
        #expect(preview.image != nil && preview.icon != nil)
        // 脚本没有执行；苹果触控图标比 16 像素的图标先用。
        #expect(StubURLProtocol.requested(host: host).sorted() == [url("/card.png"), url("/repo"), url("/touch.png")])
    }

    @Test func cookiesAreNeitherSentNorStored() async throws {
        let cookie = HTTPCookie(properties: [.domain: host, .path: "/", .name: "session", .value: "secret"])!
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }
        StubURLProtocol.set(.page("<title>x</title>"), for: url("/a"))

        _ = await fetcher.fetchPreview(page("/a"))

        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func redirectsToSingleUseAddressesAreNotFollowed() async throws {
        // 短链接跳到重置密码的链接：不跟过去，只取网站图标。
        StubURLProtocol.set(.redirect("/reset?token=8f3a9c2e7b1d4f60a5c9"), for: url("/s/k9"))
        StubURLProtocol.set(.page("<link rel=\"icon\" href=\"/i.png\" sizes=\"32x32\">"), for: url("/"))
        StubURLProtocol.set(.data(png, contentType: "image/png"), for: url("/i.png"))

        let preview = try #require(await fetcher.fetchPreview(page("/s/k9")))

        #expect(!StubURLProtocol.requested(host: host).contains(url("/reset?token=8f3a9c2e7b1d4f60a5c9")))
        #expect(preview.title.isEmpty && preview.icon != nil)
    }

    @Test func redirectsToPrivateAddressesAreNotFollowed() async throws {
        StubURLProtocol.set(.redirect("http://192.168.1.1/admin"), for: url("/go"))

        _ = await fetcher.fetchPreview(page("/go"))

        #expect(StubURLProtocol.requests(host: "192.168.1.1").isEmpty)
    }

    @Test func ordinaryRedirectsAreFollowed() async throws {
        StubURLProtocol.set(.redirect("/new"), for: url("/old"))
        StubURLProtocol.set(.page("<title>新地址</title>"), for: url("/new"))

        #expect(await fetcher.fetchPreview(page("/old"))?.title == "新地址")
    }

    @Test func siteIconRequestsOnlyTheHomepageAndTheIcon() async throws {
        StubURLProtocol.set(.page("<title>首页</title><link rel=\"shortcut icon\" href=\"/fav.png\">"), for: url("/"))
        StubURLProtocol.set(.data(png, contentType: "image/png"), for: url("/fav.png"))

        let preview = try #require(await fetcher.fetchPreview(LinkPreviewRequest(url: URL(string: url("/"))!, includesPage: false)))

        // 首页的标题不当作网页标题。
        #expect(preview.title.isEmpty && preview.icon != nil)
        // 没有声明苹果触控图标时先按惯例试一下。
        #expect(StubURLProtocol.requested(host: host).sorted() == [url("/"), url("/apple-touch-icon.png"), url("/fav.png")])
    }

    @Test func faviconIsTheLastResort() async throws {
        StubURLProtocol.set(.status(500), for: url("/"))
        StubURLProtocol.set(.data(png, contentType: "image/x-icon"), for: url("/favicon.ico"))

        let preview = await fetcher.fetchPreview(LinkPreviewRequest(url: URL(string: url("/"))!, includesPage: false))

        #expect(preview?.icon != nil)
    }

    @Test func linksToFilesAreNotDownloaded() async throws {
        StubURLProtocol.set(.data(Data(count: 3_000_000), contentType: "application/octet-stream"), for: url("/app.dmg"))

        let preview = await fetcher.fetchPreview(page("/app.dmg"))

        #expect(preview?.title == "")
        #expect(preview?.image == nil)
    }

    @Test func linksToImagesUseTheImageAsPreview() async throws {
        StubURLProtocol.set(.data(png, contentType: "image/png"), for: url("/cat.png"))

        #expect(await fetcher.fetchPreview(page("/cat.png"))?.image != nil)
    }

    @Test func failuresReturnNil() async throws {
        StubURLProtocol.set(.status(404), for: url("/gone"))
        #expect(await fetcher.fetchPreview(page("/gone")) == nil)
    }

    @Test func gbkPagesAreDecoded() async throws {
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let html = try #require("<html><head><meta charset=\"gbk\"><title>新浪首页</title></head></html>".data(using: gbk))
        StubURLProtocol.set(.data(html, contentType: "text/html"), for: url("/cn"))

        #expect(await fetcher.fetchPreview(page("/cn"))?.title == "新浪首页")
    }
}

/// Reddit 这类只读 HTML 拿不到信息的网站：标题走 oEmbed 接口，图标用固定的地址，不请求网页本身。
@Suite struct KnownSiteTests {
    let fetcher = HTMLPreviewFetcher(configuration: StubURLProtocol.configuration())
    let png = ClipStoreTests.makePNG(width: 8, height: 8)!

    @Test func redditPostsGetTheirTitleFromOEmbed() async throws {
        let post = URL(string: "https://www.reddit.com/r/swift/comments/abc123/swiftui_tips/")!
        let endpoint = try #require(KnownSite.reddit.oEmbedURL(for: post))
        StubURLProtocol.set(.data(Data(#"{"title":"SwiftUI tips","provider_name":"reddit"}"#.utf8), contentType: "application/json"),
                            for: endpoint.absoluteString)
        StubURLProtocol.set(.data(png, contentType: "image/png"), for: KnownSite.reddit.iconURL.absoluteString)

        let preview = try #require(await fetcher.fetchPreview(LinkPreviewRequest(url: post, includesPage: true)))

        #expect(preview.title == "SwiftUI tips" && preview.icon != nil)
        #expect(!StubURLProtocol.requested(host: "www.reddit.com").contains(post.absoluteString))
    }

    @Test func otherRedditPagesAreNamedFromTheAddress() {
        #expect(KnownSite.matching(URL(string: "https://old.reddit.com/r/apple/")!) == .reddit)
        #expect(KnownSite.matching(URL(string: "https://redd.it/abc")!) == .reddit)
        #expect(KnownSite.matching(URL(string: "https://notreddit.com/r/apple/")!) == nil)
        #expect(KnownSite.reddit.oEmbedURL(for: URL(string: "https://www.reddit.com/r/swift/")!) == nil)
        #expect(KnownSite.reddit.fallbackTitle(for: URL(string: "https://www.reddit.com/r/swift/s/AbCdEf")!) == "r/swift")
        #expect(KnownSite.reddit.fallbackTitle(for: URL(string: "https://www.reddit.com/user/spez/")!) == "u/spez")
        #expect(KnownSite.reddit.fallbackTitle(for: URL(string: "https://www.reddit.com/")!) == nil)
    }
}

/// 从 HTML 里读标题、预览图和图标。
@Suite struct HTMLMetadataTests {
    let base = URL(string: "https://example.com/a/b.html")!

    @Test func titleComesFromOpenGraphThenTwitterThenTheTitleTag() {
        #expect(HTMLMetadata(html: "<title> 普通\n  标题 </title><meta name=\"twitter:title\" content=\"推特\">", baseURL: base).title == "推特")
        #expect(HTMLMetadata(html: "<TITLE>A &lt;b&gt; &#20320;&#x597D;</TITLE>", baseURL: base).title == "A <b> 你好")
        #expect(HTMLMetadata(html: "<body>没有标题</body>", baseURL: base).title == nil)
    }

    @Test func onlyTheHeadIsRead() {
        let html = "<head><title>头部</title></head><body><meta property=\"og:title\" content=\"正文里的\"></body>"
        #expect(HTMLMetadata(html: html, baseURL: base).title == "头部")
    }

    @Test func urlsAreResolvedAgainstTheBase() {
        let html = """
            <base href="https://cdn.example.net/assets/">
            <meta property='og:image' content='img/card.jpg'>
            <link rel=icon href=//static.example.org/i.ico>
            """
        let metadata = HTMLMetadata(html: html, baseURL: base)
        #expect(metadata.imageURL?.absoluteString == "https://cdn.example.net/assets/img/card.jpg")
        // 按惯例试的苹果触控图标在网页自己的网站根目录下，不跟着 <base>。
        #expect(metadata.iconURLs.map(\.absoluteString) == [
            "https://example.com/apple-touch-icon.png",
            "https://static.example.org/i.ico",
            "https://example.com/favicon.ico",
        ])
    }

    @Test func largerIconsComeFirstAndSVGIsSkipped() {
        let html = """
            <link rel="icon" href="/16.png" sizes="16x16">
            <link rel="icon" href="/logo.svg" type="image/svg+xml">
            <link rel="icon" href="/192.png" sizes="192x192">
            <link rel="fluid-icon" href="/fluidicon.png">
            """
        #expect(HTMLMetadata(html: html, baseURL: base).iconURLs.map(\.path) == [
            "/fluidicon.png", "/192.png", "/apple-touch-icon.png", "/16.png", "/favicon.ico",
        ])
    }

    @Test func aDeclaredTouchIconMakesTheConventionalOneUnnecessary() {
        let html = "<link rel=\"apple-touch-icon\" href=\"/touch-180.png\">"
        #expect(HTMLMetadata(html: html, baseURL: base).iconURLs.map(\.path) == ["/touch-180.png", "/favicon.ico"])
    }
}
