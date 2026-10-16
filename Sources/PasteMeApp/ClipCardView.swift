import AppKit
import PasteMeCore
import SwiftUI

/// 一张历史卡片：彩色标题栏（类型、时间、来源应用图标）+ 内容预览 + 底部信息。
struct ClipCardView: View {
    let item: ClipItem
    /// 1…9，显示 ⌘n 提示；超过 9 条为 nil。
    let shortcutIndex: Int?
    /// 当前的搜索文字。命中图片里的文字时，卡片底部显示命中的那一段。
    var searchText = ""

    static let size = CGSize(width: 230, height: 240)

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        .contentShape(Rectangle())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.kind.title)
                .font(.system(size: 13, weight: .semibold))
            Text(item.createdAt, format: .relative(presentation: .named))
                .font(.system(size: 11))
                .opacity(0.85)
        }
        .foregroundStyle(style.darkText ? Color.black.opacity(0.78) : .white)
        .padding(.leading, 10)
        .padding(.trailing, Self.headerIconSlice.width)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.headerHeight)
        .background(style.color)
        .overlay(alignment: .topTrailing) { headerIcon }
    }

    /// 标题栏里的来源应用图标：比标题栏还大，贴在右边、一部分被裁掉，带阴影，看起来从标题栏上凸出来。
    ///
    /// 放大、阴影、被标题栏和卡片右上圆角裁掉的样子都已经画进图片（见 `AppIconCache.headerIcon`），
    /// 图片正好是标题栏右端的大小，不超出标题栏，所以标题栏不用 `.clipped()`。在运行时裁切超出的大图标，
    /// 会让每张卡片在依次出现的动画里逐帧重新合成，呼出面板时大约三分之一的帧赶不上 120 Hz。
    @ViewBuilder
    private var headerIcon: some View {
        if let image = AppIconCache.headerIcon(for: item.sourceBundleID) {
            Image(nsImage: image)
                .resizable()
                .frame(width: Self.headerIconSlice.width, height: Self.headerIconSlice.height)
                .help(item.sourceName ?? "")
        }
    }

    static let cornerRadius: CGFloat = 12
    static let headerHeight: CGFloat = 48
    /// 图标放大后的边长。
    static let headerIconSize: CGFloat = 60
    /// 标题栏右端放图标的那一块，图标图片就是这么大。
    static let headerIconSlice = CGSize(width: 64, height: headerHeight)
    /// 图标在这一块里的位置（左上角为原点）：右边超出卡片 12 点，上边超出 3 点，下边超出 9 点。
    static let headerIconFrame = CGRect(x: 16, y: -3, width: headerIconSize, height: headerIconSize)

    private var style: CardStyle { CardStyle(for: item) }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            Text(item.preview ?? "")
                .font(.system(size: 12))
                .lineLimit(11)
                .foregroundStyle(.primary)
        case .link:
            VStack(alignment: .leading, spacing: 6) {
                if let host = item.preview.flatMap(URL.init(string:))?.host() {
                    Text(host)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                }
                Text(item.preview ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(6)
            }
        case .image:
            if let data = item.thumbnail, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .file:
            let paths = item.filePaths
            VStack(spacing: 6) {
                if let data = item.thumbnail, let image = NSImage(data: data) {
                    // 图片文件：显示复制时生成的缩略图，只留一行文件名。
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text(paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    if let first = paths.first {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: first))
                            .resizable()
                            .frame(width: 64, height: 64)
                    }
                    Text(paths.map { ($0 as NSString).lastPathComponent }.joined(separator: "\n"))
                        .font(.system(size: 12))
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if item.recognizedText?.isEmpty == false {
                Image(systemName: "text.viewfinder")
                    .help("图片里的文字可以搜索")
            }
            if let snippet = item.recognizedTextSnippet(matching: searchText) {
                Text(snippet.highlighted)
                    .lineLimit(1)
            } else {
                Text(detail)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let shortcutIndex {
                Text("⌘\(shortcutIndex)")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var detail: String {
        switch item.kind {
        case .text: "\(item.textLength) 个字符"
        case .link: item.sourceName ?? ""
        case .image: item.sourceName ?? ""
        case .file: item.filePaths.count == 1 ? "1 个文件" : "\(item.filePaths.count) 个文件"
        }
    }
}

/// 图片文字里命中搜索词的那一段：命中的词，以及前后几个字。
struct TextSnippet: Equatable {
    var before: String
    var match: String
    var after: String

    /// 命中的词加粗、用强调色。
    var highlighted: AttributedString {
        var match = AttributedString(match)
        match.font = .system(size: 11, weight: .semibold)
        match.foregroundColor = .accentColor
        return AttributedString(before) + match + AttributedString(after)
    }
}

extension ClipItem {
    /// 搜索词出现在图片的文字里时，取出它和前后几个字，换行换成空格。和数据库的搜索一样不区分大小写。
    func recognizedTextSnippet(matching search: String, context: Int = 6) -> TextSnippet? {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind == .image || kind == .file, !needle.isEmpty,
              let text = recognizedText,
              let range = text.range(of: needle, options: .caseInsensitive)
        else { return nil }
        func flat(_ part: Substring) -> String {
            part.replacingOccurrences(of: "\n", with: " ")
        }
        let before = text[..<range.lowerBound].suffix(context)
        let after = text[range.upperBound...].prefix(context * 3)
        return TextSnippet(
            before: (before.startIndex > text.startIndex ? "…" : "") + flat(before),
            match: flat(text[range]),
            after: flat(after) + (after.endIndex < text.endIndex ? "…" : "")
        )
    }
}

extension ClipKind {
    var title: String {
        switch self {
        case .text: "文本"
        case .link: "链接"
        case .image: "图片"
        case .file: "文件"
        }
    }

    var color: Color {
        switch self {
        case .text: Color(red: 0.25, green: 0.45, blue: 0.85)
        case .link: Color(red: 0.55, green: 0.35, blue: 0.85)
        case .image: Color(red: 0.92, green: 0.52, blue: 0.2)
        case .file: Color(red: 0.2, green: 0.62, blue: 0.6)
        }
    }
}

/// 卡片标题栏的颜色：来源应用图标的代表色，找不到图标时按类型取色。光标也用这个颜色。
@MainActor
struct CardStyle {
    var color: Color
    /// 标题栏颜色偏亮，文字用深色。
    var darkText: Bool

    init(for item: ClipItem) {
        if let rgb = AppIconCache.color(for: item.sourceBundleID) {
            color = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
            darkText = rgb.prefersDarkText
        } else {
            color = item.kind.color
            darkText = false
        }
    }
}

/// 按 bundle id 缓存来源应用的图标和图标的代表色。
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]
    private static var colors: [String: SRGBColor?] = [:]

    private static var headerIcons: [String: NSImage] = [:]

    /// 标题栏右端的图标图片：图标放大到 `ClipCardView.headerIconSize`，加上阴影，裁成标题栏右端那一块
    /// （`ClipCardView.headerIconSlice`），右上角按卡片圆角裁掉。每个应用只画一次。
    static func headerIcon(for bundleID: String?) -> NSImage? {
        guard let bundleID, let icon = icon(for: bundleID) else { return nil }
        if let cached = headerIcons[bundleID] { return cached }
        let image = drawHeaderSlice(icon)
        headerIcons[bundleID] = image
        return image
    }

    private static func drawHeaderSlice(_ icon: NSImage) -> NSImage {
        let slice = ClipCardView.headerIconSlice
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(slice.width * scale),
            pixelsHigh: Int(slice.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return icon }
        rep.size = slice

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high

        // AppKit 的坐标原点在左下角。裁掉右上角：卡片的圆角。
        let radius = ClipCardView.cornerRadius
        let clip = NSBezierPath()
        clip.move(to: .zero)
        clip.line(to: NSPoint(x: slice.width, y: 0))
        clip.line(to: NSPoint(x: slice.width, y: slice.height - radius))
        clip.appendArc(
            withCenter: NSPoint(x: slice.width - radius, y: slice.height - radius),
            radius: radius, startAngle: 0, endAngle: 90
        )
        clip.line(to: NSPoint(x: 0, y: slice.height))
        clip.close()
        clip.addClip()

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 8
        // (−1, −2) 是往左下方投影。
        shadow.shadowOffset = NSSize(width: -1, height: -2)
        shadow.set()
        let frame = ClipCardView.headerIconFrame
        let rect = NSRect(x: frame.minX, y: slice.height - frame.maxY, width: frame.width, height: frame.height)
        icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: slice)
        image.addRepresentation(rep)
        return image
    }

    /// 图标的代表色（见 `IconColor.dominant`）。找不到应用或图标全透明时为 nil。
    static func color(for bundleID: String?) -> SRGBColor? {
        guard let bundleID else { return nil }
        if let cached = colors[bundleID] { return cached }
        var rect = NSRect(x: 0, y: 0, width: 64, height: 64)
        let color = icon(for: bundleID)?
            .cgImage(forProposedRect: &rect, context: nil, hints: nil)
            .flatMap(IconColor.dominant(in:))
        colors[bundleID] = color
        return color
    }

    private static var menuIcons: [String: NSImage] = [:]

    /// 菜单里用的 16 点小图标。
    static func menuIcon(for bundleID: String) -> NSImage? {
        if let cached = menuIcons[bundleID] { return cached }
        guard let icon = icon(for: bundleID)?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        menuIcons[bundleID] = icon
        return icon
    }

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}
