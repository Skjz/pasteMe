import AppKit
import PasteMeCore
import SwiftUI

/// 一张历史卡片：彩色标题栏（类型、时间、来源应用图标）+ 内容预览 + 底部信息。
struct ClipCardView: View {
    let item: ClipItem
    /// 1…9，显示 ⌘n 提示；超过 9 条为 nil。
    let shortcutIndex: Int?
    let isSelected: Bool
    /// 焦点在卡片列表上时，选中的卡片边框更醒目，表示 ⌘⌫ 等操作会作用于它。
    let cardsFocused: Bool

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
                .strokeBorder(borderColor, lineWidth: isSelected ? 3 : 1)
        }
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        .contentShape(Rectangle())
    }

    private var borderColor: Color {
        guard isSelected else { return Color.primary.opacity(0.1) }
        return cardsFocused ? Color.accentColor : Color.accentColor.opacity(0.4)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.kind.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(item.createdAt, format: .relative(presentation: .named))
                    .font(.system(size: 11))
                    .opacity(0.85)
            }
            Spacer(minLength: 0)
            if let icon = AppIconCache.icon(for: item.sourceBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 30, height: 30)
                    .help(item.sourceName ?? "")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(item.kind.color)
    }

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

/// 按 bundle id 缓存来源应用的图标。
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}
