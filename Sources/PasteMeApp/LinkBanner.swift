import AppKit
import PasteMeCore
import SwiftUI

/// 预览窗口里链接摘要左边的一块图：有预览图时是预览图；只有网站图标时用图标的主色铺一块淡色底、图标放在中间。
/// 什么都没有时不占地方。
struct LinkBanner: View {
    let item: ClipItem
    var height: CGFloat = 66
    var iconSize: CGFloat = 36

    static func hasContent(_ item: ClipItem) -> Bool {
        item.thumbnail != nil || item.linkIcon != nil
    }

    var body: some View {
        if let data = item.thumbnail, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if let data = item.linkIcon, let style = LinkIconCache.style(for: item.id, icon: data) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(
                        colors: [style.tint.opacity(0.32), style.tint.opacity(0.14)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    // 灰色系的图标在浅色模式下底色很淡，加一圈描边，不和背景融在一起。
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08)))
                SiteIcon(style: style, size: iconSize)
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
        }
    }
}

/// 链接图标的图片、主色和四角是否透明，以及卡片上带光晕的图标。每个条目的图标只算一次、画一次。
@MainActor
enum LinkIconCache {
    struct Style {
        let image: NSImage
        let tint: Color
        let isTransparent: Bool
        /// 图标的主色，读不出来时为 nil。
        let rgb: SRGBColor?
    }

    private struct Key: Hashable {
        let id: Int64
        let size: Int
    }

    private static var styles: [Key: Style] = [:]
    private static var posterIcons: [Key: NSImage] = [:]

    /// 光晕超出图标的宽度（点）。
    static let glow: CGFloat = 18

    /// 图标读不出来时为 nil。重新获取后图标的大小一般会变，按大小区分新旧。
    static func style(for id: Int64, icon data: Data) -> Style? {
        let key = Key(id: id, size: data.count)
        if let cached = styles[key] { return cached }
        guard let image = NSImage(data: data) else { return nil }
        var rect = NSRect(x: 0, y: 0, width: 64, height: 64)
        let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        let rgb = cgImage.flatMap(IconColor.dominant(in:))
        let style = Style(
            image: image,
            tint: rgb.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? Color.gray,
            isTransparent: cgImage.map(cornersAreTransparent) ?? false,
            rgb: rgb
        )
        styles[key] = style
        return style
    }

    /// 卡片上的网站图标：圆角方块（四角透明的垫白底、加一圈细边），外面一圈图标颜色的光，整个画成一张图，
    /// 四周比图标大 `glow`。光晕在运行时画的话，每张卡片在依次出现的动画里都要重新模糊一次。
    static func posterIcon(for id: Int64, icon data: Data, style: Style, size: CGFloat) -> NSImage {
        let key = Key(id: id, size: data.count)
        if let cached = posterIcons[key] { return cached }
        let canvas = NSSize(width: size + glow * 2, height: size + glow * 2)
        let scale = AppIconCache.bitmapScale()
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return style.image }
        rep.size = canvas

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        // AppKit 的原点在左下角：光晕往下偏 4 点。
        let rect = NSRect(x: glow, y: glow, width: size, height: size)
        let radius = size * 0.22
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let glowColor = style.rgb.map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 0.55) }
            ?? NSColor.gray.withAlphaComponent(0.55)
        let shadow = NSShadow()
        shadow.shadowColor = glowColor
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -4)

        // 先填一个圆角方块投出光晕，再把图标裁成圆角画在上面。
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        (style.isTransparent ? NSColor.white : glowColor.withAlphaComponent(1)).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let iconRect = style.isTransparent ? rect.insetBy(dx: size * 0.15, dy: size * 0.15) : rect
        style.image.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        if style.isTransparent {
            NSColor.black.withAlphaComponent(0.08).setStroke()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
            border.lineWidth = 1
            border.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: canvas)
        image.addRepresentation(rep)
        posterIcons[key] = image
        return image
    }

    /// 缩成 16×16 后，四个角的像素平均不透明度不到一半。
    private static func cornersAreTransparent(_ image: CGImage) -> Bool {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }
        let corners = [(0, 0), (side - 1, 0), (0, side - 1), (side - 1, side - 1)]
        let alpha = corners.map { x, y in Int(pixels[(y * side + x) * 4 + 3]) }.reduce(0, +)
        return alpha < 4 * 128
    }
}
