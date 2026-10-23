import Foundation
import Testing
@testable import PasteMeCore

/// 空格预览链接时在预览里显示网页（#52）：什么时候直接加载，网页里的跳转去哪里。
@Suite struct WebPreviewPolicyTests {
    @Test func webPagesLoadRightAway() {
        #expect(WebPreviewPolicy.start(for: " https://example.com/post/42\n") == .load(URL(string: "https://example.com/post/42")!))
        // 本机和内网的地址也加载：用户自己按了空格，和后台获取链接预览不一样。
        #expect(WebPreviewPolicy.start(for: "http://localhost:3000/") == .load(URL(string: "http://localhost:3000/")!))
        #expect(WebPreviewPolicy.start(for: "http://nas/photos") == .load(URL(string: "http://nas/photos")!))
    }

    @Test func trackingParametersAreDropped() {
        #expect(WebPreviewPolicy.start(for: "https://youtu.be/abc?si=Xy12Ab34Cd56Ef78") == .load(URL(string: "https://youtu.be/abc")!))
    }

    @Test func singleUseLinksWaitForTheUser() {
        let reset = "https://example.com/account/reset?token=8f14e45fceea167a5a36dedd4bea2543"
        #expect(WebPreviewPolicy.start(for: reset) == .askFirst(URL(string: reset)!))
        #expect(WebPreviewPolicy.start(for: "https://example.com/verify-email") == .askFirst(URL(string: "https://example.com/verify-email")!))
    }

    @Test func otherLinksAreNotWebPages() {
        #expect(WebPreviewPolicy.start(for: "mailto:someone@example.com") == nil)
        #expect(WebPreviewPolicy.start(for: "ftp://example.com/file") == nil)
        #expect(WebPreviewPolicy.start(for: "") == nil)
    }

    private func navigation(_ address: String?, clicked: Bool = false, newWindow: Bool = false) -> WebPreviewPolicy.Navigation {
        WebPreviewPolicy.navigation(to: address.flatMap(URL.init(string:)), userClicked: clicked, opensNewWindow: newWindow)
    }

    @Test func redirectsStayInThePreview() {
        #expect(navigation("https://example.com/next") == .allow)
        #expect(navigation("about:blank") == .allow)
    }

    @Test func clickedLinksAndNewWindowsOpenOutside() {
        #expect(navigation("https://example.com/other", clicked: true) == .openOutside)
        #expect(navigation("https://example.com/popup", newWindow: true) == .openOutside)
        #expect(navigation("mailto:someone@example.com", clicked: true) == .openOutside)
    }

    @Test func pagesCannotOpenAppsOnTheirOwn() {
        // 网页自己跳到 zoommtg:// 这类地址会打开别的应用，只有用户点的才放行。
        #expect(navigation("zoommtg://zoom.us/join?confno=1") == .cancel)
        #expect(navigation("javascript:alert(1)", clicked: true) == .cancel)
        #expect(navigation(nil) == .cancel)
    }
}
