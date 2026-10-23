import AppKit
import PasteMeCore
import SwiftUI

/// 链接卡片上显示的文字：标题（网页标题，没有时从网址读出）和网站（去掉 www. 的域名）。
struct LinkText: Equatable {
    var headline: String
    var site: String

    init(headline: String, site: String) {
        self.headline = headline
        self.site = site
    }

    init(item: ClipItem) {
        let url = item.preview.flatMap(URL.init(string:))
        site = url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? ""
        if let title = item.linkTitle, !title.isEmpty {
            headline = title
        } else {
            headline = url.flatMap(Self.headline(from:)) ?? site
        }
    }

    /// 网址里不像标题的路径：语言、`wiki`、`watch` 这类固定的段。
    private static let filler: Set<String> = [
        "wiki", "watch", "index", "home", "p", "s", "post", "posts", "article", "articles", "blog", "news",
        "a", "en", "en-us", "en-gb", "zh", "zh-cn", "zh-hans", "zh-tw", "zh-hant", "ja", "ja-jp", "cn", "us", "item",
        "r", "u", "user", "users", "comments", "status", "video", "videos", "questions",
        "issues", "pull", "tree", "blob", "commit",
    ]

    /// 从网址的路径读出标题：去掉固定的段和扩展名，连字符换成空格；只有两段时写成「a / b」（GitHub 的「用户 / 仓库」）。
    /// 路径里只有编号或随机字符时为 nil，用域名。
    static func headline(from url: URL) -> String? {
        let parts = url.pathComponents
            .filter { $0 != "/" }
            .map { $0.removingPercentEncoding ?? $0 }
            .map { ($0 as NSString).deletingPathExtension }
            .filter { !filler.contains($0.lowercased()) && !looksLikeID($0) }
        guard !parts.isEmpty else { return nil }
        let words = parts.map { $0.replacingOccurrences(of: "[-_+]+", with: " ", options: .regularExpression) }
        return words.count == 2 ? words.joined(separator: " / ") : words.last
    }

    /// 只有数字，或者字母和数字混在一起、像编号的一段（`1o6ky4f`、`BV1GJ411x7h7`）。
    private static func looksLikeID(_ part: String) -> Bool {
        if part.allSatisfy(\.isNumber) { return true }
        let hasDigit = part.contains(where: \.isNumber)
        let hasLetter = part.contains(where: \.isLetter)
        return hasDigit && hasLetter && !part.contains("-") && !part.contains("_") && part.count >= 6
    }
}

/// 杂志风格用的衬线字体：拉丁字母用 New York，中文换成宋体。按字号缓存：每次画卡片都新建字体描述，
/// 呼出面板时 `show()` 会多花几毫秒。
@MainActor
enum EditorialFont {
    private static var fonts: [CGFloat: Font] = [:]

    static func serif(_ size: CGFloat) -> Font {
        if let cached = fonts[size] { return cached }
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        var font = Font(base)
        if let serif = base.fontDescriptor.withDesign(.serif) {
            let songti = NSFontDescriptor(fontAttributes: [.family: "Songti SC"]).withSymbolicTraits(.bold)
            font = Font(NSFont(descriptor: serif.addingAttributes([.cascadeList: [songti]]), size: size) ?? base)
        }
        fonts[size] = font
        return font
    }
}

/// 海报样式的衬线标题，链接卡片和文件卡片共用。
struct PosterHeadline: View {
    let text: String
    let size: CGFloat
    let lines: Int

    var body: some View {
        Text(text)
            .font(EditorialFont.serif(size))
            .multilineTextAlignment(.center)
            .lineLimit(lines)
            .frame(maxWidth: .infinity)
    }
}

/// 海报样式标题下面夹在两条细线中间的大写小字：链接的网站名，文件的类型和大小。
struct PosterCaption: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            rule
            Text(text.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            rule
        }
    }

    private var rule: some View {
        Rectangle().fill(Color.primary.opacity(0.25)).frame(width: 14, height: 0.5)
    }
}

/// 从内容区顶上散开的一片图标颜色，垫在海报样式的图标后面。
struct PosterGlow: View {
    let tint: Color

    var body: some View {
        RadialGradient(colors: [tint.opacity(0.22), .clear], center: .top, startRadius: 0, endRadius: 140)
            .padding(-10)
    }
}

/// 链接卡片的内容区，海报样式：居中，网站图标带一圈图标颜色的光，下面是衬线标题和夹在两条细线中间的网站名；
/// 有预览图时预览图在上面。还没获取或获取失败时是域名和网址。
struct LinkCardContent: View {
    let item: ClipItem

    static let iconSize: CGFloat = 50

    private var text: LinkText { LinkText(item: item) }
    private var picture: NSImage? { item.thumbnail.flatMap(NSImage.init(data:)) }

    var body: some View {
        if let picture {
            VStack(spacing: 8) {
                Image(nsImage: picture)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                PosterHeadline(text: text.headline, size: 15, lines: 2)
                PosterCaption(text: text.site)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let data = item.linkIcon, let style = LinkIconCache.style(for: item.id, icon: data) {
            VStack(spacing: 8) {
                // 光晕已经画进图片，图片比图标大一圈，用负的边距让图标本身对齐。
                Image(nsImage: LinkIconCache.posterIcon(for: item.id, icon: data, style: style, size: Self.iconSize))
                    .resizable()
                    .frame(width: Self.iconSize + LinkIconCache.glow * 2, height: Self.iconSize + LinkIconCache.glow * 2)
                    .padding(-LinkIconCache.glow)
                    .padding(.top, 6)
                PosterHeadline(text: text.headline, size: 18, lines: 3)
                PosterCaption(text: text.site)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(alignment: .top) { PosterGlow(tint: style.tint) }
        } else {
            plain
        }
    }

    private var plain: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text.site)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Text(item.preview ?? "")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                .lineLimit(6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 网站图标：不透明的裁成圆角方块，四角透明的垫一块白底。
struct SiteIcon: View {
    let style: LinkIconCache.Style
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        if style.isTransparent {
            Image(nsImage: style.image)
                .resizable()
                .interpolation(.high)
                .frame(width: size * 0.7, height: size * 0.7)
                .frame(width: size, height: size)
                .background(shape.fill(Color.white))
                .overlay(shape.strokeBorder(Color.black.opacity(0.08)))
        } else {
            Image(nsImage: style.image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(shape)
        }
    }
}
