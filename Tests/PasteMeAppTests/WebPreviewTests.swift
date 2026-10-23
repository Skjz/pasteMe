import Foundation
import Testing
@testable import PasteMeApp
import PasteMeCore

/// 链接卡片的预览显示网页（#52）：什么时候显示网页、什么时候显示网址编辑器，加载失败时怎么说。
@MainActor
@Suite struct WebPreviewTests {
    private func item(_ kind: ClipKind) -> ClipItem {
        ClipItem(id: 1, kind: kind, preview: nil, textLength: 0, thumbnail: nil, sourceBundleID: nil, sourceName: nil, createdAt: Date())
    }

    @Test func linksShowTheWebPageUnlessBeingEdited() {
        let state = PreviewState()
        state.load(item(.link), content: ClipContent(kind: .link, text: "https://example.com"))
        #expect(state.showsWebPage && !state.bodyIsEditable)

        // ⌘E、右键「编辑…」：改网址。
        state.load(item(.link), content: ClipContent(kind: .link, text: "https://example.com"), editing: true)
        #expect(!state.showsWebPage && state.bodyIsEditable)
    }

    @Test func linksThatAreNotWebPagesShowTheAddress() {
        let state = PreviewState()
        state.load(item(.link), content: ClipContent(kind: .link, text: "mailto:someone@example.com"))
        #expect(!state.showsWebPage && state.bodyIsEditable)
    }

    @Test func otherKindsNeverShowAWebPage() {
        let state = PreviewState()
        state.load(item(.text), content: ClipContent(kind: .text, text: "https://example.com"))
        #expect(!state.showsWebPage && state.bodyIsEditable)
        state.load(nil, content: nil)
        #expect(!state.showsWebPage && state.bodyIsEditable)
    }

    @Test func failuresAreExplained() {
        func message(_ code: Int) -> String {
            WebPreviewLoader.message(for: NSError(domain: NSURLErrorDomain, code: code))
        }
        #expect(message(NSURLErrorNotConnectedToInternet) == "没有连上网络")
        #expect(message(NSURLErrorTimedOut) == "网站太久没有响应")
        #expect(message(NSURLErrorCannotFindHost) == "找不到这个网站")
        #expect(message(NSURLErrorServerCertificateUntrusted) == "网站的安全证书有问题，没有打开")
    }

    @Test func singleUseLinksWaitWithoutCreatingAWebView() {
        let loader = WebPreviewLoader()
        loader.show("https://example.com/reset?token=8f14e45fceea167a5a36dedd4bea2543")
        #expect(loader.phase == .askFirst(URL(string: "https://example.com/reset?token=8f14e45fceea167a5a36dedd4bea2543")!))
        loader.show("https://example.com/", after: WebPreviewLoader.followDelay)
        #expect(loader.phase == .waiting)
        loader.stop()
        #expect(loader.phase == .idle)
    }
}

/// 预览窗口不是 key 时，第一下点击也要交给网页（在真实应用里发现：点网页里的链接要点两次）。
@MainActor
@Suite struct PreviewWebViewTests {
    @Test func theFirstClickReachesThePage() {
        let view = PreviewWebView(frame: .zero)
        #expect(view.acceptsFirstMouse(for: nil))
        #expect(view.needsPanelToBecomeKey)
    }
}
