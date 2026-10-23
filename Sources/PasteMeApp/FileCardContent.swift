import AppKit
import PasteMeCore
import SwiftUI
import UniformTypeIdentifiers

/// 文件卡片上的文字：衬线标题和夹在细线中间的类型、大小。
struct FileCardText: Equatable {
    var headline: String
    var caption: String

    init(headline: String, caption: String) {
        self.headline = headline
        self.caption = caption
    }

    /// - Parameter facts: 路径现在的样子。还没读到时为 nil，先只按路径写，读到以后卡片重画。
    init(paths: [String], facts: (String) -> FileFacts?) {
        if paths.count == 1, let path = paths.first {
            let facts = facts(path)
            headline = Self.headline(ofPath: path, kind: facts?.kind)
            caption = Self.caption(ofPath: path, facts: facts)
            return
        }
        let kinds = paths.map { facts($0)?.kind }
        let folders = kinds.filter { $0 == .folder }.count
        switch folders {
        case 0: headline = "\(paths.count) 个文件"
        case paths.count: headline = "\(paths.count) 个文件夹"
        default: headline = "\(paths.count) 项"
        }
        var names: [String] = []
        for (path, kind) in zip(paths, kinds) {
            let name = Self.kindName(ofPath: path, kind: kind)
            if !names.contains(name) { names.append(name) }
        }
        caption = names.prefix(3).joined(separator: " · ") + (names.count > 3 ? " …" : "")
    }

    /// 文件名去掉扩展名。文件夹和扩展名不认识的（「v1.2」这样的名字）写全名。
    static func headline(ofPath path: String, kind: FileFacts.Kind?) -> String {
        let name = (path as NSString).lastPathComponent
        guard kind != .folder, knownType(of: path) != nil else { return name }
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }

    /// 类型：扩展名的大写，文件夹和应用写中文，没有认识的扩展名时写「文件」。
    static func kindName(ofPath path: String, kind: FileFacts.Kind?) -> String {
        if kind == .folder { return "文件夹" }
        guard let type = knownType(of: path) else { return "文件" }
        if type.conforms(to: .application) { return "应用程序" }
        return (path as NSString).pathExtension.uppercased()
    }

    /// 类型后面写文件的大小、图片的像素或文件夹的项数。文件已经不在了就只写这一句。
    static func caption(ofPath path: String, facts: FileFacts?) -> String {
        let kind = kindName(ofPath: path, kind: facts?.kind)
        guard let facts else { return kind }
        guard facts.kind != nil else { return "已经不在原处" }
        if let count = facts.itemCount { return "\(kind) · \(count) 项" }
        if let pixels = facts.pixelSize { return "\(kind) · \(pixels.width) × \(pixels.height)" }
        if let bytes = facts.byteCount {
            return "\(kind) · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        return kind
    }

    /// 系统认识的扩展名对应的类型。没有扩展名、或者扩展名不对应任何类型时为 nil。
    static func knownType(of path: String) -> UTType? {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic else { return nil }
        return type
    }

    /// 卡片底部写的位置：几个文件共同所在的文件夹，家目录写成 ~，超过三层只留最后两层。
    static func location(of paths: [String]) -> String {
        guard let first = paths.first else { return "" }
        func folder(_ path: String) -> [String] {
            ((path as NSString).deletingLastPathComponent as NSString).pathComponents
        }
        var common = folder(first)
        for path in paths.dropFirst() {
            common = zip(common, folder(path)).prefix { $0 == $1 }.map(\.0)
        }
        let short = (NSString.path(withComponents: common) as NSString).abbreviatingWithTildeInPath
        let parts = short.split(separator: "/")
        return parts.count > 3 ? "…/" + parts.suffix(2).joined(separator: "/") : short
    }
}

/// 文件卡片的内容区，和链接卡片一样是海报样式：居中的图标带一圈图标颜色的光，下面是衬线标题和夹在两条细线
/// 中间的类型、大小。图片文件在上面显示缩略图，PDF 这类有缩略图的文稿显示成一页纸，几个文件时图标摊成扇形。
/// 文件已经不在原处时图标是灰的。
struct FileCardContent: View {
    let item: ClipItem

    static let iconSize: CGFloat = 60
    static let fanIconSize: CGFloat = 48

    var body: some View {
        let paths = item.filePaths
        let cache = FileFactsCache.shared
        let text = FileCardText(paths: paths, facts: cache.facts(for:))
        if paths.count == 1, let path = paths.first {
            let facts = cache.facts(for: path)
            let missing = facts != nil && facts?.kind == nil
            if FileCardText.knownType(of: path)?.conforms(to: .image) == true,
               let data = item.thumbnail, let picture = NSImage(data: data) {
                VStack(spacing: 8) {
                    Image(nsImage: picture)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    PosterHeadline(text: text.headline, size: 15, lines: 2)
                    PosterCaption(text: text.caption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let key = FileIconCache.iconKey(forPath: path, kind: facts?.kind)
                VStack(spacing: 8) {
                    hero(for: key, missing: missing)
                        .padding(.top, 4)
                    PosterHeadline(text: text.headline, size: 17, lines: 2)
                        .opacity(missing ? 0.5 : 1)
                    PosterCaption(text: text.caption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(alignment: .top) {
                    if !missing { PosterGlow(tint: FileIconCache.tint(for: key)) }
                }
            }
        } else {
            let shown = Array(paths.prefix(3).enumerated())
            VStack(spacing: 8) {
                ZStack {
                    ForEach(shown, id: \.offset) { index, path in
                        let facts = cache.facts(for: path)
                        let angle = (Double(index) - Double(shown.count - 1) / 2) * 14
                        icon(
                            FileIconCache.iconKey(forPath: path, kind: facts?.kind),
                            size: Self.fanIconSize,
                            missing: facts != nil && facts?.kind == nil
                        )
                        .rotationEffect(.degrees(angle))
                        .offset(x: angle * 2.1, y: abs(angle) * 0.35)
                        .zIndex(-abs(angle))
                    }
                }
                .frame(height: 62)
                .padding(.top, 4)
                PosterHeadline(text: text.headline, size: 17, lines: 1)
                PosterCaption(text: text.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(alignment: .top) {
                if let first = paths.first {
                    PosterGlow(tint: FileIconCache.tint(for: FileIconCache.iconKey(forPath: first, kind: cache.facts(for: first)?.kind)))
                }
            }
        }
    }

    /// 有缩略图的文稿（PDF）显示那一页纸，其余显示图标。
    @ViewBuilder
    private func hero(for key: FileIconCache.IconKey, missing: Bool) -> some View {
        if let data = item.thumbnail, let sheet = FileIconCache.sheet(for: item.id, thumbnail: data) {
            // 阴影已经画进图片，图片比纸大一圈，用负的边距让纸本身对齐。
            Image(nsImage: sheet)
                .resizable()
                .frame(width: sheet.size.width, height: sheet.size.height)
                .padding(-FileIconCache.sheetMargin)
        } else {
            icon(key, size: Self.iconSize, missing: missing)
        }
    }

    /// 光晕已经画进图片，图片比图标大一圈，用负的边距让图标本身对齐。
    private func icon(_ key: FileIconCache.IconKey, size: CGFloat, missing: Bool) -> some View {
        Image(nsImage: FileIconCache.poster(for: key, size: size, missing: missing))
            .resizable()
            .frame(width: size + FileIconCache.glow * 2, height: size + FileIconCache.glow * 2)
            .padding(-FileIconCache.glow)
    }
}
