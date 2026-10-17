import Foundation

/// 只下载网页的 HTML，从里面读出标题、预览图和网站图标（#11）。
///
/// 比系统的 LinkPresentation 保守：不执行网页里的脚本（有的页面用脚本自动提交表单），不带也不存 Cookie，
/// 不加载网页上的其他资源，网页读到 `</head>` 为止（最多 2 MB），不是网页的链接（安装包、视频）不下载。
/// 重定向到本机、内网地址不跟；打开复制的网址时，重定向到看起来像一次性的网址也不跟
/// （短链接跳到重置密码的链接），这时退回只取网站图标。
public struct HTMLPreviewFetcher: LinkPreviewFetching {
    /// 有的网页在 `<head>` 里先放了很长的内联脚本（YouTube 的标题在 750 KB 之后），所以上限放宽，读到 `</head>` 就停。
    public static let maxPageBytes = 2 * 1024 * 1024
    public static let maxImageBytes = 5 * 1024 * 1024
    /// 网站图标存的边长（像素）。卡片上显示成 44 点，Retina 屏幕要 88 像素以上。
    public static let iconPixelSize = 128

    private let session: URLSession

    /// `configuration` 只在测试时替换（换成假的网络）。
    public init(configuration: URLSessionConfiguration = HTMLPreviewFetcher.defaultConfiguration()) {
        session = URLSession(configuration: configuration)
    }

    /// 不带 Cookie、不缓存、不存登录信息；单次请求 10 秒、整个下载 15 秒超时。
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpAdditionalHeaders = [
            "User-Agent": "PasteMe-LinkPreview/1.0 (Macintosh)",
            "Accept": "text/html,application/xhtml+xml;q=0.9,image/*;q=0.8,*/*;q=0.5",
        ]
        return configuration
    }

    public func fetchPreview(_ request: LinkPreviewRequest) async -> LinkPreview? {
        if let site = KnownSite.matching(request.url) {
            return await preview(of: request, from: site)
        }
        guard request.includesPage else { return await siteIconOnly(of: request.url) }
        switch await load(request.url, maxBytes: Self.maxPageBytes, followSingleUseRedirects: false) {
        case .html(let html, let finalURL):
            let page = HTMLMetadata(html: html, baseURL: finalURL)
            async let image = thumbnail(of: page.imageURL, maxPixelSize: Thumbnailer.maxPixelSize)
            async let icon = firstIcon(page.iconURLs)
            return LinkPreview(title: page.title ?? "", image: await image, icon: await icon)
        case .image(let data, let finalURL):
            // 链接就是一张图片：图片本身当预览图。
            async let icon = siteIconOnly(of: finalURL)?.icon
            return LinkPreview(title: "", image: Thumbnailer.thumbnail(for: data), icon: await icon)
        case .other(let finalURL):
            return await siteIconOnly(of: finalURL) ?? .failed
        case .json:
            // 网址返回的是数据而不是网页（接口地址），没有可以显示的。
            return await siteIconOnly(of: request.url) ?? .failed
        case .blocked:
            return await siteIconOnly(of: request.url)
        case .failed:
            return nil
        }
    }

    /// 只读 HTML 拿不到信息的网站（`KnownSite`）：标题从 oEmbed 接口取，取不到时用网址里的名字；图标用固定的地址。
    private func preview(of request: LinkPreviewRequest, from site: KnownSite) async -> LinkPreview? {
        async let icon = thumbnail(of: site.iconURL, maxPixelSize: Self.iconPixelSize)
        guard request.includesPage else { return await icon.map { LinkPreview(title: "", icon: $0) } }
        var title: String?
        if let endpoint = site.oEmbedURL(for: request.url),
           case .json(let data) = await load(endpoint, maxBytes: 256 * 1024, followSingleUseRedirects: true),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = object["title"] as? String, !text.isEmpty {
            title = text
        }
        return LinkPreview(title: title ?? site.fallbackTitle(for: request.url) ?? "", icon: await icon)
    }

    /// 只取网站图标：读首页里声明的图标，没有时用 `/favicon.ico`。一个图标都拿不到时为 nil。
    private func siteIconOnly(of url: URL) async -> LinkPreview? {
        guard let home = LinkPreviewPolicy.homepage(of: url) else { return nil }
        var candidates: [URL] = []
        if case .html(let html, let finalURL) = await load(home, maxBytes: Self.maxPageBytes, followSingleUseRedirects: true) {
            candidates = HTMLMetadata(html: html, baseURL: finalURL).iconURLs
        } else {
            candidates = ["/apple-touch-icon.png", "/favicon.ico"].compactMap { URL(string: $0, relativeTo: home)?.absoluteURL }
        }
        return await firstIcon(candidates).map { LinkPreview(title: "", icon: $0) }
    }

    private func firstIcon(_ urls: [URL]) async -> Data? {
        for url in urls.prefix(4) {
            if let icon = await thumbnail(of: url, maxPixelSize: Self.iconPixelSize) { return icon }
        }
        return nil
    }

    private func thumbnail(of url: URL?, maxPixelSize: Int) async -> Data? {
        guard let url, LinkPreviewPolicy.allowsFetching(url),
              case .image(let data, _) = await load(url, maxBytes: Self.maxImageBytes, followSingleUseRedirects: true)
        else { return nil }
        return Thumbnailer.thumbnail(for: data, maxPixelSize: maxPixelSize)
    }

    private enum Loaded {
        case html(String, URL)
        case image(Data, URL)
        case json(Data)
        /// 不是网页也不是图片，没有下载内容。
        case other(URL)
        /// 重定向被拦下了。
        case blocked
        case failed
    }

    private func load(_ url: URL, maxBytes: Int, followSingleUseRedirects: Bool) async -> Loaded {
        let guardian = RedirectGuard(followSingleUse: followSingleUseRedirects)
        do {
            let (bytes, response) = try await session.bytes(for: URLRequest(url: url), delegate: guardian)
            defer { bytes.task.cancel() }
            if guardian.blocked { return .blocked }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return .failed }
            let finalURL = http.url ?? url
            let type = http.mimeType?.lowercased() ?? ""
            if type == "text/html" || type == "application/xhtml+xml" {
                let data = try await Self.read(bytes, upTo: maxBytes, stoppingAfter: Data("</head>".utf8))
                return .html(Self.decode(data, declaredEncoding: http.textEncodingName), finalURL)
            }
            if type == "application/json" || type.hasSuffix("+json") {
                return .json(try await Self.read(bytes, upTo: maxBytes))
            }
            if type.hasPrefix("image/"), type != "image/svg+xml" {
                // 图片太大时不要了：读到上限还没完就放弃。
                let data = try await Self.read(bytes, upTo: maxBytes + 1)
                return data.count > maxBytes ? .other(finalURL) : .image(data, finalURL)
            }
            return .other(finalURL)
        } catch {
            return guardian.blocked ? .blocked : .failed
        }
    }

    /// 读到 `limit` 字节，或者读到 `marker` 为止（每 16 KB 看一次刚读到的部分，不区分大小写的 ASCII）。
    private static func read(_ bytes: URLSession.AsyncBytes, upTo limit: Int, stoppingAfter marker: Data? = nil) async throws -> Data {
        var data = Data()
        data.reserveCapacity(min(limit, 64 * 1024))
        let step = 16 * 1024
        var checked = 0
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
            if let marker, data.count - checked >= step {
                let start = max(0, checked - marker.count)
                if Self.lowercasedASCII(data[start...]).range(of: marker) != nil { break }
                checked = data.count
            }
        }
        return data
    }

    private static func lowercasedASCII(_ data: Data) -> Data {
        Data(data.map { (65...90).contains($0) ? $0 + 32 : $0 })
    }

    /// 按响应头里的编码解码，没有时看网页开头的 `<meta charset>`，都没有时按 UTF-8。中文网站常用 GBK。
    static func decode(_ data: Data, declaredEncoding: String?) -> String {
        let sniffed = declaredEncoding ?? sniffCharset(data)
        if let name = sniffed, let encoding = encoding(named: name), let text = String(data: data, encoding: encoding) {
            return text
        }
        // 截在多字节字符中间时严格解码会失败，宽松地解码。
        return String(decoding: data, as: UTF8.self)
    }

    private static func encoding(named name: String) -> String.Encoding? {
        let lower = name.lowercased()
        if ["gbk", "gb2312", "gb18030", "x-gbk"].contains(lower) {
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        }
        let cf = CFStringConvertIANACharSetNameToEncoding(lower as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    private static func sniffCharset(_ data: Data) -> String? {
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        guard let range = head.range(of: "charset=") else { return nil }
        let rest = head[range.upperBound...].drop { $0 == "\"" || $0 == "'" }
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }
}

/// 拦下不该跟的重定向：本机和内网地址总是不跟；打开复制的网址时，看起来像一次性的网址也不跟。
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let followSingleUse: Bool
    private let lock = NSLock()
    private var _blocked = false

    init(followSingleUse: Bool) {
        self.followSingleUse = followSingleUse
    }

    var blocked: Bool { lock.withLock { _blocked } }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url, LinkPreviewPolicy.allowsFetching(url),
              followSingleUse || !LinkPreviewPolicy.looksSingleUse(url)
        else {
            lock.withLock { _blocked = true }
            task.cancel()
            return nil
        }
        return request
    }
}

/// 从网页的 `<head>` 里读出的标题、预览图和图标。不执行脚本，只看 HTML 标签。
struct HTMLMetadata: Equatable {
    var title: String?
    var imageURL: URL?
    /// 网站图标，大的在前：声明的苹果触控图标（通常 180 像素）和 `fluid-icon`（GitHub 用它放 512 像素的图标）、
    /// 声明 96 像素以上的图标、没声明苹果触控图标时按惯例试 `/apple-touch-icon.png`、小图标，最后是 `/favicon.ico`。
    var iconURLs: [URL]

    init(html: String, baseURL: URL) {
        let head = html.range(of: "</head>", options: .caseInsensitive).map { String(html[..<$0.lowerBound]) } ?? html
        var base = baseURL
        var metaTitle: String?
        var image: URL?
        var icons: [(url: URL, rank: Int)] = []

        for tag in Self.matches(of: Self.tagPattern, in: head) {
            let name = tag[1].lowercased()
            let attributes = Self.attributes(in: tag[0])
            switch name {
            case "base":
                if let href = attributes["href"], let url = URL(string: href, relativeTo: baseURL) { base = url.absoluteURL }
            case "meta":
                let key = (attributes["property"] ?? attributes["name"] ?? "").lowercased()
                guard let content = attributes["content"].map(Self.decodeEntities), !content.isEmpty else { continue }
                if ["og:title", "twitter:title"].contains(key), metaTitle == nil {
                    metaTitle = content
                } else if ["og:image", "og:image:url", "og:image:secure_url", "twitter:image", "twitter:image:src"].contains(key),
                          image == nil, let url = URL(string: content, relativeTo: base) {
                    image = url.absoluteURL
                }
            case "link":
                let rel = (attributes["rel"] ?? "").lowercased().split(separator: " ").map(String.init)
                guard rel.contains(where: { $0 == "icon" || $0 == "fluid-icon" || $0.hasPrefix("apple-touch-icon") }),
                      let href = attributes["href"].map(Self.decodeEntities),
                      !href.lowercased().hasSuffix(".svg"), attributes["type"]?.lowercased() != "image/svg+xml",
                      let url = URL(string: href, relativeTo: base)
                else { continue }
                let size = attributes["sizes"].flatMap { Int($0.lowercased().split(separator: "x").first ?? "") } ?? 16
                let rank = rel.contains { $0.hasPrefix("apple-touch-icon") } ? 1_000 : rel.contains("fluid-icon") ? 900 : size
                icons.append((url.absoluteURL, rank))
            default:
                break
            }
        }

        let titleTag = Self.matches(of: Self.titlePattern, in: head).first.map { Self.decodeEntities($0[1]) }
        title = [metaTitle, titleTag].compactMap { $0.map(Self.collapseWhitespace) }.first { !$0.isEmpty }.map { String($0.prefix(300)) }
        imageURL = image
        if icons.allSatisfy({ $0.rank < 1_000 }), let touch = URL(string: "/apple-touch-icon.png", relativeTo: baseURL)?.absoluteURL {
            icons.append((touch, 95))
        }
        iconURLs = icons.sorted { $0.rank > $1.rank }.map(\.url)
        if let favicon = URL(string: "/favicon.ico", relativeTo: baseURL)?.absoluteURL, !iconURLs.contains(favicon) {
            iconURLs.append(favicon)
        }
    }

    private static let tagPattern = try! NSRegularExpression(pattern: "<(meta|link|base)\\b[^>]*>", options: .caseInsensitive)
    private static let titlePattern = try! NSRegularExpression(
        pattern: "<title\\b[^>]*>(.*?)</title>",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let attributePattern = try! NSRegularExpression(
        pattern: "([a-zA-Z_:][-a-zA-Z0-9_:.]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))"
    )

    /// 每个匹配的整段和各个分组。
    private static func matches(of pattern: NSRegularExpression, in text: String) -> [[String]] {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    private static func attributes(in tag: String) -> [String: String] {
        var attributes: [String: String] = [:]
        for match in matches(of: attributePattern, in: tag) {
            let value = [match[2], match[3], match[4]].first { !$0.isEmpty } ?? ""
            attributes[match[1].lowercased()] = attributes[match[1].lowercased()] ?? value
        }
        return attributes
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 常见的命名实体和数字实体。
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[amp...]
            guard let semicolon = after.prefix(10).firstIndex(of: ";") else {
                result += "&"
                rest = after.dropFirst()
                continue
            }
            let entity = after[after.index(after: amp)..<semicolon]
            if let decoded = decode(entity: entity) {
                result += decoded
                rest = after[after.index(after: semicolon)...]
            } else {
                result += "&"
                rest = after.dropFirst()
            }
        }
        return result + rest
    }

    private static func decode(entity: Substring) -> String? {
        switch entity {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default:
            guard entity.hasPrefix("#") else { return nil }
            let number = entity.dropFirst()
            let value = number.first == "x" || number.first == "X" ? UInt32(number.dropFirst(), radix: 16) : UInt32(number)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
    }
}
