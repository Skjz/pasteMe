import AppKit
import ImageIO
import PasteMeCore
import QuickLookThumbnailing
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import PasteMeApp

// PROTOTYPE：文件、文件夹卡片的三个设计方向（海报、目录、封面）和现状，渲染成图片，拼成一个对比页面。
// 只在设置了 PASTEME_PROTOTYPE_OUT 时运行：
//   PASTEME_PROTOTYPE_OUT=<目录> swift test --filter FileCardPrototype

/// 原型里用到的文件信息，直接从文件系统读。
@MainActor
struct FileFacts {
    var path: String
    var exists: Bool
    var isFolder: Bool
    var isPackage: Bool
    /// 图片文件：卡片上整张显示缩略图。PDF 也有缩略图，但当作文稿，显示成一页纸。
    var isImage: Bool
    var size: Int64?
    var modified: Date?
    var pixelSize: CGSize?
    var children: [String]
    var icon: NSImage
    var tint: Color
    /// 写字用的颜色：图标颜色够鲜艳时用它，黑白灰的图标（大多数文稿）用次要文字色。
    var accent: Color
    /// Quick Look 画的内容缩略图（文稿的第一页、代码的文字），没有时为 nil。
    var page: NSImage?

    static var pages: [String: NSImage] = [:]

    init(_ path: String) {
        self.path = path
        var isDirectory: ObjCBool = false
        exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        // 替身（/Applications/Safari.app 这类符号链接）按它指向的东西算。
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        isFolder = isDirectory.boolValue && !isPackage
        isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        size = isDirectory.boolValue ? nil : (attributes?[.size] as? NSNumber)?.int64Value
        modified = attributes?[.modificationDate] as? Date
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            pixelSize = CGSize(width: width, height: height)
        }
        children = isFolder
            ? ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
                .filter { !$0.hasPrefix(".") }
                .sorted { a, b in
                    let aFolder = FileFacts.isDirectory((path as NSString).appendingPathComponent(a))
                    let bFolder = FileFacts.isDirectory((path as NSString).appendingPathComponent(b))
                    if aFolder != bFolder { return aFolder }
                    return a.localizedStandardCompare(b) == .orderedAscending
                }
            : []
        icon = Self.bitmap(exists
            ? NSWorkspace.shared.icon(forFile: url.path)
            : NSWorkspace.shared.icon(for: .init(filenameExtension: url.pathExtension) ?? .data))
        var rect = NSRect(x: 0, y: 0, width: 64, height: 64)
        let rgb = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil).flatMap(IconColor.dominant(in:))
        tint = exists ? rgb.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? .gray : .gray
        let vivid = rgb.map { max($0.red, $0.green, $0.blue) - min($0.red, $0.green, $0.blue) > 0.25 } ?? false
        accent = exists && vivid ? tint : .secondary
        page = Self.pages[path]
    }

    /// 竖着的一页纸（PDF、文稿）。Quick Look 给代码和纯文本画的是方块，不当作纸。
    var portraitPage: NSImage? {
        guard let page, page.size.height > page.size.width * 1.2 else { return nil }
        return page
    }

    /// 图标先画成位图。ImageRenderer 直接画应用的图标时，整张卡片的底色会变灰。
    static func bitmap(_ icon: NSImage) -> NSImage {
        var rect = NSRect(x: 0, y: 0, width: 256, height: 256)
        guard let cgImage = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return icon }
        return NSImage(cgImage: cgImage, size: NSSize(width: 128, height: 128))
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    var name: String { (path as NSString).lastPathComponent }
    /// 标题：文件名去掉扩展名，文件夹用全名。
    var headline: String { isFolder ? name : (name as NSString).deletingPathExtension }
    var ext: String { (name as NSString).pathExtension.uppercased() }

    var sizeText: String? { size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } }

    /// 类型：扩展名，文件夹、应用写成中文。
    var kindText: String {
        if isFolder { return "文件夹" }
        if isPackage, ext == "APP" { return "应用程序" }
        return ext.isEmpty ? "文件" : ext
    }

    /// 类型和大小（文件夹是项数，图片是像素）。
    var meta: String {
        guard exists else { return "已经不在原处" }
        if isFolder { return "文件夹 · \(children.count) 项" }
        if let pixelSize { return "\(kindText) · \(Int(pixelSize.width)) × \(Int(pixelSize.height))" }
        return [kindText, isPackage ? nil : sizeText].compactMap { $0 }.joined(separator: " · ")
    }

    /// 底部显示的位置：用 ~ 缩写，太深时只留最后两层。
    var location: String { Self.location(of: (path as NSString).deletingLastPathComponent) }

    static func location(of folder: String) -> String {
        let short = (folder as NSString).abbreviatingWithTildeInPath
        let parts = short.split(separator: "/").map(String.init)
        return parts.count > 3 ? "…/" + parts.suffix(2).joined(separator: "/") : short
    }

    static func files(of item: ClipItem) -> [FileFacts] { item.filePaths.map(FileFacts.init) }

    /// 几个文件在同一个文件夹里时是那个文件夹，否则写个数。
    static func footer(for files: [FileFacts]) -> String {
        let parents = Set(files.map { ($0.path as NSString).deletingLastPathComponent })
        if parents.count == 1, let first = files.first { return first.location }
        return "\(files.count) 个文件"
    }
}

// MARK: - 共用的小部件

/// 夹在两条细线中间的大写小字，和链接卡片的网站名一样。
private struct CapsLine: View {
    let text: String
    var rules = true

    var body: some View {
        HStack(spacing: 6) {
            if rules { rule }
            Text(text.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if rules { rule }
        }
    }

    private var rule: some View {
        Rectangle().fill(Color.primary.opacity(0.25)).frame(width: 14, height: 0.5)
    }
}

private struct Caps: View {
    let text: String
    var color: Color = .secondary
    var tracking: CGFloat = 1.3

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 8, weight: .bold))
            .tracking(tracking)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

private struct FileIcon: View {
    let file: FileFacts
    let size: CGFloat
    var glow = true

    var body: some View {
        Image(nsImage: file.icon)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .saturation(file.exists ? 1 : 0)
            .opacity(file.exists ? 1 : 0.4)
            .shadow(color: glow ? file.tint.opacity(0.55) : .clear, radius: size * 0.2, y: size * 0.08)
    }
}

/// 一张纸：Quick Look 画的内容缩略图垫白底、加阴影；没有内容缩略图时用图标。
private struct Sheet: View {
    let file: FileFacts
    let width: CGFloat

    var body: some View {
        if let page = file.portraitPage {
            Image(nsImage: page)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: width)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .shadow(color: .black.opacity(0.28), radius: 6, y: 3)
        } else {
            Image(nsImage: file.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: width, height: width)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        }
    }
}

private func fanAngle(_ index: Int, of count: Int, step: Double) -> Double {
    (Double(index) - Double(count - 1) / 2) * step
}

// MARK: - 现状：和 ClipCardView 里的一样，只是图标先画成位图

struct CurrentFileContent: View {
    let item: ClipItem

    var body: some View {
        let paths = item.filePaths
        VStack(spacing: 6) {
            if let data = item.thumbnail, let image = NSImage(data: data) {
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
                    Image(nsImage: FileFacts.bitmap(NSWorkspace.shared.icon(forFile: first)))
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

// MARK: - A 海报：和链接卡片一样居中，图标带一圈光，衬线标题，细线中间是类型和大小

struct PosterFileContent: View {
    let item: ClipItem
    private var files: [FileFacts] { FileFacts.files(of: item) }

    var body: some View {
        let files = files
        if files.count == 1, let file = files.first {
            if file.isImage, let data = item.thumbnail, let picture = NSImage(data: data) {
                VStack(spacing: 8) {
                    Image(nsImage: picture)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    headline(file.headline, size: 15, lines: 2)
                    CapsLine(text: file.meta)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Group {
                        if file.portraitPage != nil {
                            Sheet(file: file, width: 48)
                        } else {
                            FileIcon(file: file, size: 60)
                        }
                    }
                    .padding(.top, 4)
                    headline(file.headline, size: 17, lines: 2)
                        .opacity(file.exists ? 1 : 0.5)
                    CapsLine(text: file.meta)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(alignment: .top) { glow(file.tint) }
            }
        } else {
            VStack(spacing: 8) {
                ZStack {
                    let shown = Array(files.prefix(3).enumerated())
                    ForEach(shown, id: \.offset) { index, file in
                        let angle = fanAngle(index, of: shown.count, step: 14)
                        FileIcon(file: file, size: 48)
                            .rotationEffect(.degrees(angle))
                            .offset(x: angle * 2.1, y: abs(angle) * 0.35)
                            .zIndex(-abs(angle))
                    }
                }
                .frame(height: 62)
                .padding(.top, 4)
                headline("\(files.count) 个文件", size: 17, lines: 1)
                CapsLine(text: Array(NSOrderedSet(array: files.map(\.kindText)).array as! [String]).prefix(3).joined(separator: " · "))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(alignment: .top) { glow(files.first?.tint ?? .gray) }
        }
    }

    private func headline(_ text: String, size: CGFloat, lines: Int) -> some View {
        Text(text)
            .font(EditorialFont.serif(size))
            .multilineTextAlignment(.center)
            .lineLimit(lines)
            .frame(maxWidth: .infinity)
    }

    private func glow(_ tint: Color) -> some View {
        RadialGradient(colors: [tint.opacity(0.2), .clear], center: .top, startRadius: 0, endRadius: 140)
            .padding(-10)
    }
}

// MARK: - B 目录：左对齐的版式，上面是类型（栏目名），衬线大标题，细线下面是规格或内容目录

struct IndexFileContent: View {
    let item: ClipItem
    private var files: [FileFacts] { FileFacts.files(of: item) }

    var body: some View {
        let files = files
        if files.count == 1, let file = files.first {
            if file.isImage, let data = item.thumbnail, let picture = NSImage(data: data) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(nsImage: picture)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 102)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    Text(file.headline)
                        .font(EditorialFont.serif(14))
                        .lineLimit(1)
                    Caps(text: [file.meta, file.sizeText].compactMap { $0 }.joined(separator: " · "))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if file.isFolder {
                folder(file)
            } else {
                single(file)
            }
        } else {
            several(files)
        }
    }

    private func kicker(_ file: FileFacts, _ text: String) -> some View {
        HStack(spacing: 5) {
            FileIcon(file: file, size: 16, glow: false)
            Caps(text: text, color: file.accent)
        }
    }

    private func single(_ file: FileFacts) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            kicker(file, file.kindText)
            Text(file.headline)
                .font(EditorialFont.serif(20))
                .lineLimit(3)
                .opacity(file.exists ? 1 : 0.45)
                .padding(.top, 8)
            Spacer(minLength: 8)
            Rectangle().fill(Color.primary.opacity(0.15)).frame(height: 0.5)
            HStack(alignment: .top, spacing: 18) {
                if file.exists {
                    spec("大小", file.sizeText ?? "—")
                    if let modified = file.modified {
                        spec("修改", Text(modified, format: .relative(presentation: .named)))
                    }
                } else {
                    spec("状态", "已经不在原处")
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func folder(_ file: FileFacts) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            kicker(file, "文件夹 · \(file.children.count) 项")
            Text(file.headline)
                .font(EditorialFont.serif(22))
                .lineLimit(1)
                .padding(.top, 6)
            Rectangle().fill(Color.primary.opacity(0.15)).frame(height: 0.5)
                .padding(.vertical, 8)
            let limit = 8
            let shown = file.children.count > limit ? Array(file.children.prefix(limit - 1)) : file.children
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 5) {
                ForEach(shown, id: \.self) { child in
                    HStack(spacing: 4) {
                        Image(nsImage: FileFacts((file.path as NSString).appendingPathComponent(child)).icon)
                            .resizable()
                            .frame(width: 13, height: 13)
                        Text(child)
                            .font(.system(size: 10.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if file.children.count > limit {
                    Text("还有 \(file.children.count - shown.count) 项")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func several(_ files: [FileFacts]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(files.count)").font(EditorialFont.serif(30))
                Text("个文件").font(EditorialFont.serif(14))
            }
            Rectangle().fill(Color.primary.opacity(0.15)).frame(height: 0.5)
                .padding(.top, 4)
            ForEach(Array(files.prefix(4).enumerated()), id: \.offset) { index, file in
                HStack(spacing: 6) {
                    Text(String(format: "%02d", index + 1))
                        .font(EditorialFont.serif(11))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, alignment: .leading)
                    FileIcon(file: file, size: 14, glow: false)
                    Text(file.name)
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(file.isFolder ? "\(file.children.count) 项" : file.sizeText ?? "")
                        .font(.system(size: 9.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
                if index < min(files.count, 4) - 1 {
                    Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func spec(_ label: String, _ value: String) -> some View {
        spec(label, Text(value))
    }

    private func spec(_ label: String, _ value: Text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Caps(text: label, tracking: 1)
            value
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
    }
}

// MARK: - C 封面：内容铺满，左上是栏目和衬线标题，文稿第一页、图标像实物一样从下边缘露出来；图片整张铺满

struct CoverFileContent: View {
    let item: ClipItem
    private var files: [FileFacts] { FileFacts.files(of: item) }

    var body: some View {
        let files = files
        Group {
            if files.count == 1, let file = files.first, file.isImage, let data = item.thumbnail, let picture = NSImage(data: data) {
                photo(file, picture)
            } else {
                still(files)
            }
        }
        .clipped()
        .padding(-10)
    }

    private func photo(_ file: FileFacts, _ picture: NSImage) -> some View {
        Color.clear
            .overlay {
                Image(nsImage: picture)
                    .resizable()
                    .scaledToFill()
            }
            .clipped()
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 80)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Caps(text: file.meta, color: .white.opacity(0.8))
                    Text(file.headline)
                        .font(EditorialFont.serif(17))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
                .padding(12)
            }
    }

    private func still(_ files: [FileFacts]) -> some View {
        let first = files.first
        let tint = first?.tint ?? .gray
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [tint.opacity(0.3), tint.opacity(0.05)], startPoint: .top, endPoint: .bottom)
            objects(files)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            VStack(alignment: .leading, spacing: 4) {
                if files.count == 1, let first {
                    Caps(text: first.meta, color: first.accent)
                    Text(first.headline)
                        .font(EditorialFont.serif(18))
                        .lineLimit(3)
                        .opacity(first.exists ? 1 : 0.45)
                } else {
                    Caps(text: Array(NSOrderedSet(array: files.map(\.kindText)).array as! [String]).prefix(3).joined(separator: " · "), color: first?.accent ?? .secondary)
                    Text("\(files.count) 个文件")
                        .font(EditorialFont.serif(18))
                }
            }
            .frame(maxWidth: 150, alignment: .leading)
            .padding(12)
        }
    }

    @ViewBuilder
    private func objects(_ files: [FileFacts]) -> some View {
        if files.count == 1, let file = files.first {
            if file.isFolder {
                // 文件夹：里面的几样东西从文件夹口露出来。
                let inside = file.children.prefix(3).map { FileFacts((file.path as NSString).appendingPathComponent($0)) }
                ZStack(alignment: .bottom) {
                    ForEach(Array(inside.enumerated()), id: \.offset) { index, child in
                        let angle = fanAngle(index, of: inside.count, step: 12)
                        Sheet(file: child, width: 46)
                            .rotationEffect(.degrees(angle))
                            .offset(x: angle * 1.8, y: -62)
                    }
                    FileIcon(file: file, size: 104, glow: false)
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                }
                .offset(x: -20, y: 22)
            } else if file.portraitPage != nil {
                Sheet(file: file, width: 104)
                    .rotationEffect(.degrees(5))
                    .offset(x: -18, y: 44)
            } else {
                FileIcon(file: file, size: 100, glow: false)
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                    .rotationEffect(.degrees(-6))
                    .offset(x: -16, y: 18)
            }
        } else {
            let shown = Array(files.prefix(3).enumerated())
            ZStack(alignment: .bottom) {
                ForEach(shown, id: \.offset) { index, file in
                    let angle = fanAngle(index, of: shown.count, step: 10)
                    Sheet(file: file, width: 70)
                        .rotationEffect(.degrees(angle), anchor: .bottom)
                        .offset(x: angle * 3.2)
                        .zIndex(Double(index))
                }
            }
            .offset(x: -40, y: 40)
        }
    }
}

// MARK: - 渲染

@MainActor
@Suite struct FileCardPrototype {
    nonisolated static let output = ProcessInfo.processInfo.environment["PASTEME_PROTOTYPE_OUT"]

    enum Variant: String, CaseIterable {
        case current, poster, index, cover

        var title: String {
            switch self {
            case .current: "现状"
            case .poster: "A 海报"
            case .index: "B 目录"
            case .cover: "C 封面"
            }
        }

        var note: String {
            switch self {
            case .current: "现在的样子：图标和文件名居中"
            case .poster: "和链接卡片同一套：图标带一圈光，衬线标题，细线中间写类型和大小"
            case .index: "左对齐的版式：类型像栏目名，衬线大标题，细线下面是规格；文件夹列出里面的东西，多个文件排成编号的目录"
            case .cover: "内容铺满整块：左上是标题，文稿的第一页、文件夹里的东西像实物一样从下边缘露出来；图片整张铺满"
            }
        }

        @MainActor func install() {
            switch self {
            case .current:
                FileCardPrototypeHook.content = { AnyView(CurrentFileContent(item: $0)) }
                FileCardPrototypeHook.detail = nil
            case .poster:
                FileCardPrototypeHook.content = { AnyView(PosterFileContent(item: $0)) }
            case .index:
                FileCardPrototypeHook.content = { AnyView(IndexFileContent(item: $0)) }
            case .cover:
                FileCardPrototypeHook.content = { AnyView(CoverFileContent(item: $0)) }
            }
            if self != .current {
                FileCardPrototypeHook.detail = { FileFacts.footer(for: FileFacts.files(of: $0)) }
            }
        }
    }

    @Test(.enabled(if: output != nil))
    func render() async throws {
        let out = URL(fileURLWithPath: try #require(Self.output))
        let samples = out.appendingPathComponent("文稿/项目资料")
        try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        let report = samples.appendingPathComponent("2026 第三季度经营报告.pdf")
        Self.makeReport(at: report)
        let photo = samples.appendingPathComponent("海岸航拍.heic")
        if !FileManager.default.fileExists(atPath: photo.path) {
            try FileManager.default.copyItem(atPath: "/System/Library/Wallpapers/.default/DefaultAerial.heic", toPath: photo.path)
        }
        let notes = samples.appendingPathComponent("会议纪要.md")
        try Data("# 会议纪要\n\n- 卡片重新设计\n- 预览窗口\n- 发布 0.2.0\n".utf8).write(to: notes)
        let repo = "/Users/lixiang/fromGit/pasteMe"

        let cases: [(String, [String])] = [
            ("PDF 文稿", [report.path]),
            ("代码文件", ["\(repo)/Sources/PasteMeApp/ClipCardView.swift"]),
            ("图片文件", [photo.path]),
            ("文件夹", [repo]),
            ("多个文件", [report.path, photo.path, notes.path]),
            ("已经不在的文件", [samples.appendingPathComponent("旧版报价单.xlsx").path]),
        ]

        // Quick Look 的内容缩略图：文稿的第一页、代码和 Markdown 的文字。
        for path in cases.flatMap(\.1) + FileFacts(repo).children.prefix(3).map({ "\(repo)/\($0)" }) {
            let request = QLThumbnailGenerator.Request(
                fileAt: URL(fileURLWithPath: path), size: CGSize(width: 220, height: 300), scale: 2, representationTypes: .thumbnail
            )
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                FileFacts.pages[path] = representation.nsImage
            }
        }

        var items = cases.enumerated().map { index, entry in
            ClipItem(
                id: Int64(index + 1), kind: .file, preview: entry.1.joined(separator: "\n"), textLength: 0,
                thumbnail: entry.1.count == 1 ? Thumbnailer.thumbnail(forFileAt: URL(fileURLWithPath: entry.1[0])) : nil,
                sourceBundleID: "com.apple.finder", sourceName: "访达", createdAt: Date().addingTimeInterval(-Double(index + 1) * 240)
            )
        }
        // 参照：链接卡片。
        let safariIcon = NSWorkspace.shared.icon(forFile: "/Applications/Safari.app")
        var rect = NSRect(x: 0, y: 0, width: 128, height: 128)
        let iconPNG = safariIcon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            .flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
        let link = ClipItem(
            id: 100, kind: .link, preview: "https://github.com/Skjz/pasteMe", textLength: 31, thumbnail: nil,
            sourceBundleID: "com.apple.Safari", sourceName: "Safari", createdAt: Date().addingTimeInterval(-60),
            linkTitle: "PasteMe：Mac 上的剪贴板历史", linkIcon: iconPNG
        )
        items.insert(link, at: 0)
        let names = ["链接卡片（参照）"] + cases.map(\.0)

        var images: [String: String] = [:]
        var rendered: [String: CGImage] = [:]
        for (path, page) in FileFacts.pages { print("[page] \((path as NSString).lastPathComponent) \(page.size)") }
        for variant in Variant.allCases {
            variant.install()
            for (index, item) in items.enumerated() {
                for dark in [false, true] {
                    let card = ClipCardView(item: item, shortcutIndex: nil)
                        .padding(10)
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let renderer = ImageRenderer(content: card)
                    renderer.scale = 2
                    renderer.isOpaque = false
                    var image: CGImage?
                    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { image = renderer.cgImage }
                    image = image.map { Self.onCardColor($0, dark: dark) }
                    let png = try #require(image.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) })
                    images["\(variant.rawValue)-\(index)-\(dark ? "dark" : "light")"] = png.base64EncodedString()
                    rendered["\(variant.rawValue)-\(index)-\(dark ? "dark" : "light")"] = image
                }
            }
        }
        FileCardPrototypeHook.content = nil
        FileCardPrototypeHook.detail = nil

        // 每种卡片一张图：四个方向排成一行，方便逐行看。
        let rows = out.appendingPathComponent("rows")
        try FileManager.default.createDirectory(at: rows, withIntermediateDirectories: true)
        for index in items.indices {
            for theme in ["light", "dark"] {
                let cards = Variant.allCases.compactMap { rendered["\($0.rawValue)-\(index)-\(theme)"] }
                guard let first = cards.first else { continue }
                let width = first.width * cards.count, height = first.height
                guard let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { continue }
                context.setFillColor(theme == "dark" ? CGColor(gray: 0.12, alpha: 1) : CGColor(gray: 0.9, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                for (column, card) in cards.enumerated() {
                    context.draw(card, in: CGRect(x: column * first.width, y: 0, width: first.width, height: height))
                }
                if let sheet = context.makeImage(),
                   let png = NSBitmapImageRep(cgImage: sheet).representation(using: .png, properties: [:]) {
                    try png.write(to: rows.appendingPathComponent("\(index)-\(theme).png"))
                }
            }
        }

        let variants = Variant.allCases.map { ["key": $0.rawValue, "title": $0.title, "note": $0.note] }
        let data = try JSONSerialization.data(withJSONObject: ["variants": variants, "names": names, "images": images])
        let template = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("FileCardPrototype.html"), encoding: .utf8)
        try template.replacingOccurrences(of: "/*DATA*/null", with: String(decoding: data, as: UTF8.self))
            .write(to: out.appendingPathComponent("file-cards.html"), atomically: true, encoding: .utf8)
    }

    /// 把渲染好的卡片叠在卡片底色上，卡片四角以外保持透明。
    static func onCardColor(_ card: CGImage, dark: Bool) -> CGImage {
        guard let context = CGContext(
            data: nil, width: card.width, height: card.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return card }
        let inset = CGFloat(card.width) * 10 / (ClipCardView.size.width + 20)
        let radius = CGFloat(card.width) * ClipCardView.cornerRadius / (ClipCardView.size.width + 20)
        let rect = CGRect(x: 0, y: 0, width: card.width, height: card.height).insetBy(dx: inset + 1, dy: inset + 1)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(dark ? CGColor(gray: 0.118, alpha: 1) : CGColor(gray: 1, alpha: 1))
        context.fillPath()
        context.draw(card, in: CGRect(x: 0, y: 0, width: card.width, height: card.height))
        return context.makeImage() ?? card
    }

    /// 一份有封面的 PDF：深色标题栏、几段文字和一张柱状图，Quick Look 画出来的第一页像一份真的报告。
    static func makeReport(at url: URL) {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSColor(srgbRed: 0.11, green: 0.2, blue: 0.34, alpha: 1).setFill()
        NSRect(x: 0, y: 842 - 230, width: 595, height: 230).fill()
        func draw(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, width: CGFloat = 500) {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
            NSAttributedString(string: text, attributes: attributes).draw(with: NSRect(x: point.x, y: point.y, width: width, height: 400), options: [.usesLineFragmentOrigin])
        }
        draw("QUARTERLY REPORT", at: NSPoint(x: 48, y: 842 - 80), size: 12, weight: .semibold, color: NSColor.white.withAlphaComponent(0.6))
        draw("2026 第三季度\n经营报告", at: NSPoint(x: 48, y: 842 - 190), size: 40, weight: .bold, color: .white)
        draw("营收与用户", at: NSPoint(x: 48, y: 842 - 290), size: 20, weight: .semibold, color: NSColor(white: 0.15, alpha: 1))
        let paragraph = "本季度活跃用户继续增长，剪贴板历史的平均保留时长从两周提高到一个月。预览窗口和网页卡片上线后，用户每天打开面板的次数明显增加。"
        draw(paragraph + paragraph, at: NSPoint(x: 48, y: 842 - 400), size: 12, color: NSColor(white: 0.3, alpha: 1))
        let colors: [NSColor] = [.systemBlue, .systemTeal, .systemOrange, .systemPink]
        for (index, height) in [120.0, 170, 150, 230].enumerated() {
            colors[index].setFill()
            NSBezierPath(roundedRect: NSRect(x: 60 + Double(index) * 120, y: 120, width: 70, height: height), xRadius: 6, yRadius: 6).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
    }
}
