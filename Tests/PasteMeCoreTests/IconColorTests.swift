import CoreGraphics
import Testing
@testable import PasteMeCore

@Suite struct IconColorTests {
    /// 画一张 64×64 的图：先铺满 `background`（nil 为透明），再在左下角画 `fraction` 面积的 `patch`。
    private func image(background: SRGBColor?, patch: SRGBColor? = nil, fraction: Double = 0) -> CGImage {
        let size = 64
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        if let background {
            context.setFillColor(red: background.red, green: background.green, blue: background.blue, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
        if let patch {
            context.setFillColor(red: patch.red, green: patch.green, blue: patch.blue, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: Double(size), height: Double(size) * fraction))
        }
        return context.makeImage()!
    }

    private func close(_ a: SRGBColor?, _ b: SRGBColor, tolerance: Double = 0.03) -> Bool {
        guard let a else { return false }
        return abs(a.red - b.red) < tolerance && abs(a.green - b.green) < tolerance && abs(a.blue - b.blue) < tolerance
    }

    static let white = SRGBColor(red: 1, green: 1, blue: 1)
    static let yellow = SRGBColor(red: 1, green: 0.8, blue: 0.1)
    static let blue = SRGBColor(red: 0.1, green: 0.45, blue: 0.95)
    static let gray = SRGBColor(red: 0.3, green: 0.3, blue: 0.3)

    @Test func picksVividColorOverWhiteBackground() {
        // 备忘录这类图标：大面积白色，顶上一条黄色。
        let color = IconColor.dominant(in: image(background: Self.white, patch: Self.yellow, fraction: 0.3))
        #expect(close(color, Self.yellow))
    }

    @Test func ignoresTransparentPixels() {
        let color = IconColor.dominant(in: image(background: nil, patch: Self.blue, fraction: 0.5))
        #expect(close(color, Self.blue))
    }

    @Test func grayscaleIconUsesAverageColor() {
        let color = IconColor.dominant(in: image(background: Self.gray))
        #expect(close(color, Self.gray))
    }

    @Test func aFewColoredPixelsDoNotColorAGrayIcon() {
        let color = IconColor.dominant(in: image(background: Self.gray, patch: Self.blue, fraction: 0.03))
        #expect(color.map { $0.hsb.saturation < 0.2 } == true)
    }

    @Test func fullyTransparentIconHasNoColor() {
        #expect(IconColor.dominant(in: image(background: nil)) == nil)
    }

    @Test func lightColorsGetDarkText() {
        #expect(Self.yellow.prefersDarkText)
        #expect(Self.white.prefersDarkText)
        #expect(!Self.blue.prefersDarkText)
        #expect(!Self.gray.prefersDarkText)
    }
}
