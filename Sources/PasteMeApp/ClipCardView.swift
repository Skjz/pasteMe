import AppKit
import PasteMeCore
import SwiftUI

/// 一张历史卡片：彩色标题栏（类型、时间、来源应用图标）+ 内容预览 + 底部信息。
struct ClipCardView: View {
    let item: ClipItem
    /// 1…9，显示 ⌘n 提示；超过 9 条为 nil。
    let shortcutIndex: Int?

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
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
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
        .padding(.trailing, Self.headerIconSize)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.color)
        .overlay(alignment: .trailing) { headerIcon }
        // 图标比标题栏高，超出标题栏的部分裁掉；右上角由卡片的圆角裁掉。
        .clipped()
    }

    /// 标题栏里的来源应用图标：比标题栏还大，贴在右边、一部分被裁掉，带阴影，看起来从标题栏上凸出来。
    @ViewBuilder
    private var headerIcon: some View {
        if let icon = AppIconCache.icon(for: item.sourceBundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.headerIconSize, height: Self.headerIconSize)
                .shadow(color: .black.opacity(0.3), radius: 4, x: -1, y: 2)
                .offset(x: Self.headerIconSize * 0.2, y: 3)
                .help(item.sourceName ?? "")
        }
    }

    static let headerIconSize: CGFloat = 60

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
        HStack {
            Text(detail)
            Spacer()
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

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}
