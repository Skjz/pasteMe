import Foundation
import Testing
@testable import PasteMeCore

/// 记下请求了什么，按预设返回结果。
final class FakeLinkFetcher: LinkPreviewFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [LinkPreviewRequest] = []
    private let result: LinkPreview?

    init(result: LinkPreview?) {
        self.result = result
    }

    var requests: [LinkPreviewRequest] { lock.withLock { _requests } }
    var requested: [URL] { requests.map(\.url) }

    func fetchPreview(_ request: LinkPreviewRequest) async -> LinkPreview? {
        lock.withLock { _requests.append(request) }
        return result
    }
}

/// 链接预览：按设置的档位请求，不请求本机和内网地址，像一次性的链接只请求网站首页，失败后不再重试，
/// 搜索能找到网页标题（#11）。
@MainActor
@Suite final class LinkPreviewTests {
    let store: ClipStore
    var mode = LinkPreviewMode.full

    init() throws {
        store = try ClipStore(path: ":memory:")
    }

    private func queue(_ fetcher: FakeLinkFetcher) -> EnrichmentQueue {
        EnrichmentQueue(store: store, enrichers: [
            LinkPreviewEnricher(fetcher: fetcher) { [unowned self] in self.mode },
        ])
    }

    private func recordLink(_ text: String, with queue: EnrichmentQueue) async throws -> Int64 {
        let id = try #require(try Recorder(store: store, enrichment: queue).record(ClipContent(kind: .link, text: text), from: nil))
        await queue.waitUntilIdle()
        return id
    }

    @Test func copiedLinksGetTheirTitleImageAndIcon() async throws {
        let fetcher = FakeLinkFetcher(result: LinkPreview(title: "Swift 仓库", image: Data([1]), icon: Data([2])))
        let id = try await recordLink("https://github.com/swiftlang/swift", with: queue(fetcher))

        let item = try #require(try store.item(id: id))
        #expect(item.linkTitle == "Swift 仓库")
        #expect(item.thumbnail == Data([1]) && item.linkIcon == Data([2]))
        #expect(try store.items(matching: ClipQuery(text: "仓库")).map(\.id) == [id])
        #expect(fetcher.requested == [URL(string: "https://github.com/swiftlang/swift")!])
    }

    @Test func nothingIsRequestedWhileTheSettingIsOff() async throws {
        mode = .off
        let fetcher = FakeLinkFetcher(result: LinkPreview(title: "x"))
        let queue = queue(fetcher)
        let id = try await recordLink("https://example.com", with: queue)

        #expect(fetcher.requested.isEmpty)
        // 没有标记成获取过：打开开关后再复制一次就会获取。
        mode = .full
        _ = try await recordLink("https://example.com", with: queue)
        #expect(try store.item(id: id)?.linkTitle == "x")
    }

    @Test func failuresAreRememberedAndNotRetried() async throws {
        let fetcher = FakeLinkFetcher(result: nil)
        let queue = queue(fetcher)
        let id = try await recordLink("https://example.com", with: queue)
        #expect(try store.item(id: id)?.linkTitle == "")

        _ = try await recordLink("https://example.com", with: queue)
        #expect(fetcher.requested.count == 1)
    }

    @Test func localAndPrivateAddressesAreNeverRequested() async throws {
        let fetcher = FakeLinkFetcher(result: LinkPreview(title: "x"))
        let queue = queue(fetcher)
        for link in ["http://localhost:8080/admin", "http://192.168.1.1/", "http://nas/share"] {
            _ = try await recordLink(link, with: queue)
        }
        #expect(fetcher.requested.isEmpty)
    }

    @Test func siteIconModeOnlyRequestsTheHomepage() async throws {
        mode = .siteIcon
        let fetcher = FakeLinkFetcher(result: LinkPreview(title: "", icon: Data([2])))
        let id = try await recordLink("https://github.com/swiftlang/swift?tab=readme", with: queue(fetcher))

        #expect(fetcher.requests == [LinkPreviewRequest(url: URL(string: "https://github.com/")!, includesPage: false)])
        #expect(try store.item(id: id)?.linkIcon == Data([2]))
    }

    @Test func singleUseLinksOnlyGetTheSiteIconEvenInFullMode() async throws {
        let fetcher = FakeLinkFetcher(result: LinkPreview(title: ""))
        _ = try await recordLink("https://accounts.example.com/reset?token=8f3a9c2e7b1d4f60a5c9e8d7", with: queue(fetcher))

        #expect(fetcher.requests == [LinkPreviewRequest(url: URL(string: "https://accounts.example.com/")!, includesPage: false)])
    }

    @Test func singleUseLinksAreRecognized() {
        let singleUse = [
            "https://example.com/reset-password?token=abc",
            "https://example.com/auth/magic?t=1",
            "https://example.com/verify/4b1e",
            "https://mail.example.com/unsubscribe/x",
            "https://example.com/l?code=123456",
            "https://example.com/a?sig=x&expires=1",
            "https://example.com/i/550e8400-e29b-41d4-a716-446655440000",
            "https://example.com/s/aZ3kP9qW2xL7mN4vB8cD",
            "https://example.com/p?ref=eyJhbGciOiJIUzI1NiJ9xyz",
            "https://app.example.com/callback#access_token=abc",
            "https://example.com/invite/team",
        ]
        let ordinary = [
            "https://github.com/swiftlang/swift",
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://zh.wikipedia.org/wiki/剪贴板",
            "https://news.example.com/2026/10/16/how-to-build-a-mac-app",
            "https://www.google.com/search?q=pasteme",
            "https://example.com/docs#installation",
        ]
        for link in singleUse {
            #expect(LinkPreviewPolicy.looksSingleUse(URL(string: link)!), "\(link)")
        }
        for link in ordinary {
            #expect(!LinkPreviewPolicy.looksSingleUse(URL(string: link)!), "\(link)")
        }
    }

    @Test func trackingParametersAreDroppedBeforeJudgingAndRequesting() {
        let shared = URL(string: "https://youtu.be/dQw4w9WgXcQ?si=AbCdEfGh12345678&t=42")!
        #expect(LinkPreviewPolicy.request(for: shared, mode: .full)
            == LinkPreviewRequest(url: URL(string: "https://youtu.be/dQw4w9WgXcQ?t=42")!, includesPage: true))

        let reddit = URL(string: "https://www.reddit.com/r/apple/comments/1o6ky4f/?share_id=tDWr0gkqKkYsPiY_1aYqA&utm_medium=ios_app")!
        #expect(LinkPreviewPolicy.request(for: reddit, mode: .full)?.url.absoluteString
            == "https://www.reddit.com/r/apple/comments/1o6ky4f/")
        // 令牌不是跟踪参数，照样只取网站图标。
        let reset = URL(string: "https://example.com/reset?token=abc&utm_source=mail")!
        #expect(LinkPreviewPolicy.request(for: reset, mode: .full)?.includesPage == false)
    }

    @Test func requestFollowsTheMode() {
        let page = URL(string: "https://user:pw@example.com:8443/a/b?c=d#e")!
        #expect(LinkPreviewPolicy.request(for: page, mode: .off) == nil)
        #expect(LinkPreviewPolicy.request(for: page, mode: .siteIcon)
            == LinkPreviewRequest(url: URL(string: "https://example.com:8443/")!, includesPage: false))
        #expect(LinkPreviewPolicy.request(for: page, mode: .full) == LinkPreviewRequest(url: page, includesPage: true))
        #expect(LinkPreviewPolicy.request(for: URL(string: "http://192.168.1.1/")!, mode: .full) == nil)
    }

    @Test func policyAllowsOnlyPublicWebAddresses() {
        let allowed = ["https://github.com/a/b", "http://example.com:8080/x", "https://8.8.8.8/", "https://172.32.0.1/"]
        let blocked = [
            "http://localhost/", "http://app.localhost/", "http://printer.local/", "http://intranet/",
            "http://10.0.0.5/", "http://127.0.0.1:3000/", "http://169.254.1.1/", "http://172.16.0.1/",
            "http://172.31.255.255/", "http://192.168.0.1/", "http://100.100.1.1/", "http://[::1]/",
            "http://[fe80::1]/", "http://git.corp/", "http://router.home.arpa/", "ftp://example.com/",
            "file:///etc/hosts",
        ]
        for link in allowed {
            #expect(LinkPreviewPolicy.allowsFetching(URL(string: link)!), "\(link)")
        }
        for link in blocked {
            #expect(!LinkPreviewPolicy.allowsFetching(URL(string: link)!), "\(link)")
        }
    }

    @Test func textRecognitionStillRunsAlongsideLinkPreviews() async throws {
        let recognizer = FakeRecognizer { _ in "发票" }
        let fetcher = FakeLinkFetcher(result: LinkPreview(title: "x"))
        let queue = EnrichmentQueue(store: store, enrichers: [
            TextRecognitionEnricher(recognizer: recognizer),
            LinkPreviewEnricher(fetcher: fetcher) { .full },
        ])
        let png = try #require(ClipStoreTests.makePNG(width: 4, height: 4))
        let image = try #require(try Recorder(store: store, enrichment: queue).record(ClipContent(kind: .image, image: png), from: nil))
        await queue.waitUntilIdle()

        #expect(try store.item(id: image)?.recognizedText == "发票")
        #expect(fetcher.requested.isEmpty)
    }
}
