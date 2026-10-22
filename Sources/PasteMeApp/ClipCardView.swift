import AppKit
import PasteMeCore
import SwiftUI

/// 一张历史卡片：彩色标题栏（类型、时间、来源应用图标）+ 内容预览 + 底部信息。
struct ClipCardView: View {
    let item: ClipItem
    /// 1…9，在右下角显示 ⌘n 提示。只在按住 ⌘ 时有（#39），其余时候为 nil。
    let shortcutIndex: Int?
    /// 当前的搜索文字。命中图片里的文字时，卡片底部显示命中的那一段。
    var searchText = ""
    /// 在标题栏里编辑标题时的输入框（#33），放在标题的位置。只有正在编辑的那张卡片有。
    var titleField: AnyView?

    nonisolated static let size = CGSize(width: 230, height: 240)

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
            // 起了标题的条目显示标题，否则显示类型（有文本子类型时带上，例如「文本 · Base64」）。
            if let titleField {
                titleField
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.18)))
                    .padding(.horizontal, -4)
            } else {
                Text(item.title ?? item.typeTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            subtitle
                .font(.system(size: 11))
                .lineLimit(1)
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

    /// 标题栏第二行：复制时间。起了标题的条目第一行不再是类型，类型（带文本子类型）挪到时间前面，
    /// 例如「文本 · hex · 4 分钟前」，仍然看得出是什么内容。
    private var subtitle: Text {
        let time = Text(item.createdAt, format: .relative(presentation: .named))
        return item.title == nil ? time : Text(item.typeTitle + " · ") + time
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
            textContent
        case .link:
            linkCard
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

    /// 文本卡片按子类型显示（#26、#28）：颜色是色块，时间戳带上换算出的时间，代码着色，
    /// hexdump 用等宽字体按行截断，hex 和 Base64 用等宽字体按字符换行。
    @ViewBuilder
    private var textContent: some View {
        let preview = item.preview ?? ""
        switch item.textSubtype {
        case .color where ColorValue.parse(preview) != nil:
            ColorCardContent(value: ColorValue.parse(preview)!, text: preview)
        case .timestamp where UnixTimestamp.parse(preview) != nil:
            TimestampCardContent(text: preview, date: UnixTimestamp.parse(preview)!)
        case .code(let language):
            CodeCardContent(item: item, language: language)
        case .hexdump:
            CodeCardContent(item: item, language: nil)
        case .hex, .base64:
            Text(preview)
                .font(CodeHighlightCache.font)
                .lineLimit(CodeHighlightCache.maxLines)
                .foregroundStyle(.primary)
        default:
            Text(preview)
                .font(.system(size: 12))
                .lineLimit(11)
                .foregroundStyle(.primary)
        }
    }

    private var linkCard: LinkCardContent {
        LinkCardContent(item: item)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            // 在历史里看时标出固定过的条目；在 Pinboard 里每张都是固定的，不再标。
            if !item.pinboardIDs.isEmpty, item.pinOrder == nil {
                Image(systemName: "pin.fill")
                    .help("固定在 Pinboard 里")
            }
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
        }
        // ⌘n 盖在底部右端：出现和消失时底部的文字不用重新排版，只播放提示自己的动画（#39）。
        .overlay(alignment: .trailing) {
            Group {
                if let shortcutIndex {
                    ShortcutHint(number: shortcutIndex)
                        .transition(.offset(y: ShortcutHint.outside))
                }
            }
            .animation(ShortcutHint.animation(for: shortcutIndex), value: shortcutIndex == nil)
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

/// 卡片右下角的 ⌘n（#39）。按住 ⌘ 时从卡片下边缘外面滑进来，从左到右依次出现；松开时滑回去。
/// 底部的文字很长时会伸到它下面，所以左边用卡片的底色渐隐，盖住下面的字。
private struct ShortcutHint: View {
    let number: Int

    var body: some View {
        let background = Color(nsColor: .textBackgroundColor)
        Text("⌘\(number)")
            .padding(.leading, 14)
            .background {
                LinearGradient(colors: [background.opacity(0), background], startPoint: .leading, endPoint: .center)
            }
    }

    /// 起点和终点往下移的距离：底部留白 8 点加上文字的高度，编号整个在卡片下边缘以外，被卡片的圆角裁掉，
    /// 看起来是从卡片外面进来的。
    static let outside: CGFloat = 22

    /// 编号出现、消失时用的动画，由 `.animation(_:value:)` 按有没有编号触发：模型不用包 `withAnimation`，
    /// 滚动时新进入 ⌘1…⌘9 的卡片也会滑进来、离开的滑出去。不能把动画挂在过渡上（`.transition(….animation(…))`），
    /// 那样只有透明度会动，位移直接跳到终点（`SwiftUIAssumptionTests` 检查）。
    /// 只有位移，没有淡入和缩放；进来用不回弹的短弹簧，每个编号只晚 0.01 秒，整排 0.3 秒内到位。
    static func animation(for number: Int?) -> Animation {
        guard let number else { return .easeIn(duration: 0.1) }
        return .spring(duration: 0.2, bounce: 0).delay(Double(number - 1) * 0.01)
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

extension ClipItem {
    /// 类型名，有文本子类型时带上，例如「文本 · Base64」「文本 · Swift」。
    var typeTitle: String {
        textSubtype.map { "\(kind.title) · \($0.title)" } ?? kind.title
    }
}

/// 颜色卡片（#26）：色块，下面是复制的颜色值和它的另一种写法。半透明的颜色垫在棋盘格上。
struct ColorCardContent: View {
    let value: ColorValue
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if value.alpha < 1 {
                    Checkerboard(cornerRadius: 8)
                }
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: value.alpha))
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.12))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(alternative)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// 复制的是 `#` 写法时给出 `rgb()`，否则给出 `#` 写法。
    private var alternative: String {
        func byte(_ c: Double) -> Int { Int((c * 255).rounded()) }
        let (r, g, b) = (byte(value.red), byte(value.green), byte(value.blue))
        let alpha = value.alpha < 1 ? value.alpha : nil
        if text.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            return alpha.map { "rgb(\(r) \(g) \(b) / \(Int(($0 * 100).rounded()))%)" } ?? "rgb(\(r) \(g) \(b))"
        }
        let hex = String(format: "#%02x%02x%02x", r, g, b)
        return alpha.map { hex + String(format: "%02x", byte($0)) } ?? hex
    }
}

/// 时间戳卡片（#27）：时间戳下面直接显示对应的本地时间、时区和相对时间。
struct TimestampCardContent: View {
    let text: String
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(TimestampText.local(date))
                .font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(date, format: .relative(presentation: .named))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

/// 半透明颜色下面的棋盘格，只画在圆角矩形里面。
private struct Checkerboard: View {
    let cornerRadius: CGFloat

    var body: some View {
        Canvas { context, size in
            context.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: cornerRadius))
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let cell: CGFloat = 8
            var squares = Path()
            for row in 0..<Int((size.height / cell).rounded(.up)) {
                for column in 0..<Int((size.width / cell).rounded(.up)) where (row + column).isMultiple(of: 2) {
                    squares.addRect(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
                }
            }
            context.fill(squares, with: .color(Color(white: 0.85)))
        }
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

    /// 预先画成位图的图标用的像素密度：至少 2x。位图画好后一直缓存，如果按当时的屏幕画，
    /// 只接着 1x 显示器时画的图标，之后在 Retina 屏上会发虚，直到重启（#19）。
    static func bitmapScale(screenScales: [CGFloat] = NSScreen.screens.map(\.backingScaleFactor)) -> CGFloat {
        max(2, screenScales.max() ?? 2)
    }

    private static func drawHeaderSlice(_ icon: NSImage) -> NSImage {
        let slice = ClipCardView.headerIconSlice
        let scale = bitmapScale()
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
