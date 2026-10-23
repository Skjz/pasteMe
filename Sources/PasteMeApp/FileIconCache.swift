import AppKit
import PasteMeCore
import SwiftUI
import UniformTypeIdentifiers

/// 文件卡片上的图标。带光晕的图标和 PDF 这类文稿的那一页纸都预先画成图，不在运行时模糊、加阴影：
/// 运行时的阴影会让每张卡片在依次出现的动画里逐帧重画（见 `LinkIconCache.posterIcon`）。
@MainActor
enum FileIconCache {
    /// 图标按什么缓存。普通文件的图标只看类型，同一类文件共用一张，几百张文件卡片也只画几次；
    /// 文件夹、文件包和扩展名不认识的文件可能有自己的图标（在访达里换过的图标、应用的图标），按路径。
    enum IconKey: Hashable {
        case type(String)
        case path(String)
    }

    /// 光晕超出图标的宽度（点）。
    static let glow: CGFloat = 20
    /// 纸的阴影超出纸的宽度（点）。
    static let sheetMargin: CGFloat = 10
    /// 纸最大多大：竖着的一页 A4 高 68 点，横着的幻灯片宽 80 点。
    static let sheetBox = CGSize(width: 80, height: 68)

    private struct PosterKey: Hashable {
        let icon: IconKey
        let size: Int
        let missing: Bool
    }

    private struct SheetKey: Hashable {
        let id: Int64
        let size: Int
    }

    private static var icons: [IconKey: NSImage] = [:]
    private static var tints: [IconKey: SRGBColor?] = [:]
    private static var posters: [PosterKey: NSImage] = [:]
    private static var sheets: [SheetKey: NSImage?] = [:]

    /// - Parameter kind: 路径现在是什么，还没读到时为 nil：先按扩展名猜，读到是文件夹后换成按路径。
    static func iconKey(forPath path: String, kind: FileFacts.Kind?) -> IconKey {
        guard kind != .folder, kind != .package, let type = FileCardText.knownType(of: path),
              !type.conforms(to: .directory), !type.conforms(to: .package), !type.conforms(to: .application)
        else { return .path(path) }
        return .type(type.identifier)
    }

    static func icon(for key: IconKey) -> NSImage {
        if let cached = icons[key] { return cached }
        let icon = switch key {
        case .type(let identifier): NSWorkspace.shared.icon(for: UTType(identifier) ?? .data)
        // 替身用它指向的东西的图标，不带替身的小箭头。
        case .path(let path): NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        }
        icons[key] = icon
        return icon
    }

    /// 图标的主色（`IconColor.dominant`），用在光晕和内容区顶上的那片颜色。黑白灰的图标是灰色。
    static func tint(for key: IconKey) -> Color {
        rgb(for: key).map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? .gray
    }

    private static func rgb(for key: IconKey) -> SRGBColor? {
        if let cached = tints[key] { return cached }
        var rect = NSRect(x: 0, y: 0, width: 64, height: 64)
        let rgb = icon(for: key).cgImage(forProposedRect: &rect, context: nil, hints: nil).flatMap(IconColor.dominant(in:))
        tints[key] = rgb
        return rgb
    }

    /// 卡片上的图标：外面一圈图标颜色的光，四周比图标大 `glow`。文件已经不在了的画成灰的、半透明，不带光。
    static func poster(for key: IconKey, size: CGFloat, missing: Bool) -> NSImage {
        let posterKey = PosterKey(icon: key, size: Int(size), missing: missing)
        if let cached = posters[posterKey] { return cached }
        let icon = icon(for: key)
        let canvas = NSSize(width: size + glow * 2, height: size + glow * 2)
        let rect = NSRect(x: glow, y: glow, width: size, height: size)
        let image = draw(canvas) { context in
            if missing {
                // 在一个透明图层里画图标，用饱和度混合涂成灰的，再按图标的形状把涂出去的部分去掉。
                context.setAlpha(0.4)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                context.setBlendMode(.saturation)
                context.setFillColor(NSColor.gray.cgColor)
                context.fill(rect)
                icon.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
                context.endTransparencyLayer()
            } else {
                let shadow = NSShadow()
                shadow.shadowColor = rgb(for: key).map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 0.55) }
                    ?? NSColor.gray.withAlphaComponent(0.55)
                shadow.shadowBlurRadius = size * 0.23
                // AppKit 的原点在左下角：光晕往下偏一点。
                shadow.shadowOffset = NSSize(width: 0, height: -size * 0.08)
                shadow.set()
                icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        posters[posterKey] = image
        return image
    }

    /// 复制时生成的缩略图（PDF 的第一页）画成一页纸：白底、细边、阴影，放进 `sheetBox`，四周比纸大 `sheetMargin`。
    /// 缩略图读不出来时为 nil。
    static func sheet(for id: Int64, thumbnail data: Data) -> NSImage? {
        let key = SheetKey(id: id, size: data.count)
        if let cached = sheets[key] { return cached }
        var sheet: NSImage?
        if let page = NSImage(data: data), page.size.width > 0, page.size.height > 0 {
            let scale = min(sheetBox.width / page.size.width, sheetBox.height / page.size.height)
            let pageSize = NSSize(width: (page.size.width * scale).rounded(), height: (page.size.height * scale).rounded())
            let canvas = NSSize(width: pageSize.width + sheetMargin * 2, height: pageSize.height + sheetMargin * 2)
            let rect = NSRect(origin: NSPoint(x: sheetMargin, y: sheetMargin), size: pageSize)
            let shape = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            sheet = draw(canvas) { _ in
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
                shadow.shadowBlurRadius = 6
                shadow.shadowOffset = NSSize(width: 0, height: -3)
                shadow.set()
                NSColor.white.setFill()
                shape.fill()
                NSGraphicsContext.restoreGraphicsState()

                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                page.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()

                NSColor.black.withAlphaComponent(0.1).setStroke()
                shape.lineWidth = 0.5
                shape.stroke()
            }
        }
        sheets[key] = sheet
        return sheet
    }

    /// 在一张 `canvas` 大小的透明位图上画，像素密度见 `AppIconCache.bitmapScale`。
    private static func draw(_ canvas: NSSize, _ body: (CGContext) -> Void) -> NSImage {
        let scale = AppIconCache.bitmapScale()
        let image = NSImage(size: canvas)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return image }
        // 先定好点的大小再建绘图上下文，坐标才是点而不是像素。
        rep.size = canvas
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        body(context.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        return image
    }
}
