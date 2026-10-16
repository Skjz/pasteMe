import CoreGraphics
import Foundation

/// 0…1 的 sRGB 颜色，不依赖界面框架。
public struct SRGBColor: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// 相对亮度（WCAG 的定义），0 为黑，1 为白。
    public var luminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// 背景是这个颜色时，用深色文字而不是白色文字。
    public var prefersDarkText: Bool {
        // 只按对比度算，亮度超过 0.18 就该用黑字，但中等亮度的蓝、红配白字更好看，白字对比度也还够。
        // 所以只在明显偏亮的颜色（黄、浅绿、白）上换成深色文字。
        luminance > 0.4
    }

    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let maxC = max(red, green, blue)
        let minC = min(red, green, blue)
        let delta = maxC - minC
        var hue = 0.0
        if delta > 0 {
            if maxC == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, maxC == 0 ? 0 : delta / maxC, maxC)
    }
}

/// 从应用图标里取出代表色，用作卡片标题栏的背景。
public enum IconColor {
    /// 取色时把图标缩到的边长。图标的主色在 32×32 下已经足够清楚。
    static let sampleSize = 32

    /// 图标里最显眼的颜色：鲜艳像素按色相分组，取权重最大的一组的平均色。
    /// 图标几乎没有鲜艳的颜色时（黑白灰的图标），取所有不透明像素的平均色。图标全透明时返回 nil。
    public static func dominant(in image: CGImage) -> SRGBColor? {
        let size = sampleSize
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return nil }

        let bins = 12
        var binWeight = [Double](repeating: 0, count: bins)
        var binSum = [(Double, Double, Double)](repeating: (0, 0, 0), count: bins)
        var opaqueCount = 0.0
        var opaqueSum = (0.0, 0.0, 0.0)

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[i + 3]) / 255
            guard alpha > 0.5 else { continue }
            // 去掉预乘的透明度。
            let color = SRGBColor(
                red: Double(pixels[i]) / 255 / alpha,
                green: Double(pixels[i + 1]) / 255 / alpha,
                blue: Double(pixels[i + 2]) / 255 / alpha
            )
            opaqueCount += 1
            opaqueSum.0 += color.red
            opaqueSum.1 += color.green
            opaqueSum.2 += color.blue

            let (hue, saturation, brightness) = color.hsb
            guard saturation > 0.25, brightness > 0.2 else { continue }
            let bin = min(Int(hue * Double(bins)), bins - 1)
            let weight = saturation * brightness
            binWeight[bin] += weight
            binSum[bin].0 += color.red * weight
            binSum[bin].1 += color.green * weight
            binSum[bin].2 += color.blue * weight
        }
        guard opaqueCount > 0 else { return nil }

        let best = binWeight.indices.max { binWeight[$0] < binWeight[$1] }!
        // 鲜艳像素的权重不到不透明像素的 8%，说明图标基本是黑白灰的，几个彩色像素不能代表它。
        if binWeight[best] < opaqueCount * 0.08 {
            return SRGBColor(red: opaqueSum.0 / opaqueCount, green: opaqueSum.1 / opaqueCount, blue: opaqueSum.2 / opaqueCount)
        }
        let weight = binWeight[best]
        return SRGBColor(red: binSum[best].0 / weight, green: binSum[best].1 / weight, blue: binSum[best].2 / weight)
    }
}
