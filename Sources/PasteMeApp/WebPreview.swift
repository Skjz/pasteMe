import AppKit
import Observation
import PasteMeCore
import SwiftUI
import WebKit

/// 预览窗口里的网页（#52）：链接卡片按空格时加载网页。什么时候加载、跳转去哪里由 `WebPreviewPolicy` 决定。
///
/// 网页视图第一次预览链接时才创建（要启动网页进程，比较慢），之后一直复用。用不保存数据的 `WKWebsiteDataStore`，
/// 不带登录信息，Cookie 和缓存不写到磁盘；关掉预览时再清一次，下次预览不会还是登录状态。
@Observable
@MainActor
final class WebPreviewLoader: NSObject {
    enum Phase: Equatable {
        case idle
        /// 按 ← → 换到这张卡片，停一会儿再加载。
        case waiting
        /// 像一次性的链接，等用户点「加载网页」。
        case askFirst(URL)
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase = Phase.idle
    /// 加载进度，0…1。
    private(set) var progress = 0.0

    /// 按 ← → 换卡片后停多久才加载：按住方向键快速经过的链接不加载。
    static let followDelay: TimeInterval = 0.3

    @ObservationIgnored private var webViewIfCreated: WKWebView?
    @ObservationIgnored private var pending: DispatchWorkItem?
    @ObservationIgnored private var progressObservation: NSKeyValueObservation?

    var webView: WKWebView {
        if let webViewIfCreated { return webViewIfCreated }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = PreviewWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = false
        // KVO 在主线程回调（网页视图只在主线程上用）。
        progressObservation = view.observe(\.estimatedProgress) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
        }
        webViewIfCreated = view
        return view
    }

    /// 显示这个链接的网页。`delay` 大于 0 时（按 ← → 换过来的）停这么久才开始加载，期间又换走就不加载。
    func show(_ address: String, after delay: TimeInterval = 0) {
        pending?.cancel()
        pending = nil
        webViewIfCreated?.stopLoading()
        switch WebPreviewPolicy.start(for: address) {
        case nil:
            phase = .idle
        case .askFirst(let url):
            phase = .askFirst(url)
        case .load(let url):
            guard delay > 0 else {
                load(url)
                return
            }
            phase = .waiting
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.load(url) }
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// 「加载网页」按钮，也用于失败后重试。
    func load(_ url: URL) {
        pending = nil
        phase = .loading
        progress = 0
        webView.load(URLRequest(url: url, timeoutInterval: 20))
    }

    /// 换到不是链接的卡片、进入编辑或关掉预览：停掉网页。`clearingData` 时清掉这次预览留下的 Cookie 和缓存。
    func stop(clearingData: Bool = false) {
        pending?.cancel()
        pending = nil
        phase = .idle
        guard let webView = webViewIfCreated else { return }
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        if clearingData {
            let store = webView.configuration.websiteDataStore
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        }
    }

    private func fail(_ error: Error) {
        let error = error as NSError
        // 自己停掉、换了网页，或者拦下了跳转（`decidePolicyFor` 返回 cancel）：不是加载失败。
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == WKError.errorDomain, error.code == 102 { return } // 跳转被拦下（WebKitErrorFrameLoadInterruptedByPolicyChange）
        phase = .failed(Self.message(for: error))
    }

    static func message(for error: NSError) -> String {
        guard error.domain == NSURLErrorDomain else { return "网页打不开：\(error.localizedDescription)" }
        switch error.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "没有连上网络"
        case NSURLErrorTimedOut:
            return "网站太久没有响应"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "找不到这个网站"
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorSecureConnectionFailed:
            return "网站的安全证书有问题，没有打开"
        default:
            return "网页打不开：\(error.localizedDescription)"
        }
    }
}

extension WebPreviewLoader: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        // 页面里的框架（广告、嵌入的视频）照常加载，只管主框架的跳转。
        guard navigationAction.targetFrame?.isMainFrame != false else {
            decisionHandler(.allow)
            return
        }
        let decision = WebPreviewPolicy.navigation(
            to: navigationAction.request.url,
            userClicked: navigationAction.navigationType == .linkActivated,
            opensNewWindow: false
        )
        if decision == .openOutside, let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(decision == .allow ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        // 下载文件的链接：不在预览里下载。
        if navigationResponse.isForMainFrame, !navigationResponse.canShowMIMEType {
            decisionHandler(.cancel)
            phase = .failed("这个链接是要下载的文件，没有在预览里打开")
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if phase == .loading { phase = .loaded }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    /// `target="_blank"`、`window.open`：交给默认浏览器，不在预览里开新窗口。
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let decision = WebPreviewPolicy.navigation(to: navigationAction.request.url, userClicked: false, opensNewWindow: true)
        if decision == .openOutside, let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}

/// 预览里显示网页的地方：网页铺满窗口，加载时顶边一条细的进度线，像一次性的链接、加载失败时在中间说明。
struct WebPreviewPane: View {
    let loader: WebPreviewLoader
    let address: String

    var body: some View {
        ZStack(alignment: .top) {
            WebViewHost(webView: loader.webView)
                .opacity(showsPage ? 1 : 0)
            switch loader.phase {
            case .askFirst(let url):
                notice("这个链接可能只能打开一次，打开后可能就失效了。") {
                    Button("加载网页") { loader.load(url) }
                }
            case .failed(let message):
                notice(message) {
                    if let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        Button("在浏览器中打开") { NSWorkspace.shared.open(url) }
                    }
                }
            case .loading:
                // 贴着窗口顶边的一条细线，不占网页的地方。
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * max(loader.progress, 0.05), height: 2)
                        .animation(.easeOut(duration: 0.2), value: loader.progress)
                }
                .frame(height: 2)
            case .idle, .waiting, .loaded:
                EmptyView()
            }
        }
    }

    private var showsPage: Bool {
        loader.phase == .loading || loader.phase == .loaded
    }

    private func notice(_ message: String, @ViewBuilder action: () -> some View) -> some View {
        VStack(spacing: 10) {
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            action()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 预览里的网页视图。预览窗口平时不是 key（`becomesKeyOnlyIfNeeded`），面板上的按键才照常起作用；
/// 默认的 `WKWebView` 不接受窗口不是 key 时的第一下点击，也不让窗口成为 key，点网页里的链接要点两次。
/// 这里第一下就交给网页，并让预览窗口成为 key，之后的按键（空格滚动、选字）也给网页。
final class PreviewWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
}

/// 把复用的网页视图放进 SwiftUI。视图本身由 `WebPreviewLoader` 持有，这里只负责放进去。
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }

    func updateNSView(_ view: WKWebView, context: Context) {}
}
