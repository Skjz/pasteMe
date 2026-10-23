import AppKit
import Testing
@testable import PasteMeApp
import PasteMeCore

/// 链接卡片：图标四角透明时垫白底，带光晕的图标画成一张图；没有网页标题时从网址读出标题。
@MainActor
@Suite struct LinkIconCacheTests {
    private func png(fillsCorners: Bool) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemOrange.setFill()
        let rect = NSRect(x: 0, y: 0, width: 32, height: 32)
        (fillsCorners ? NSBezierPath(rect: rect) : NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4))).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func transparentCornersAreDetected() throws {
        let round = try #require(LinkIconCache.style(for: 1, icon: png(fillsCorners: false)))
        let square = try #require(LinkIconCache.style(for: 2, icon: png(fillsCorners: true)))
        #expect(round.isTransparent)
        #expect(!square.isTransparent)
        #expect(LinkIconCache.style(for: 3, icon: Data([1, 2, 3])) == nil)
    }

    @Test func posterIconIncludesTheGlowAroundTheIcon() throws {
        let data = png(fillsCorners: true)
        let style = try #require(LinkIconCache.style(for: 4, icon: data))
        let image = LinkIconCache.posterIcon(for: 4, icon: data, style: style, size: 50)
        #expect(image.size == NSSize(width: 50 + LinkIconCache.glow * 2, height: 50 + LinkIconCache.glow * 2))
        // 同一个图标只画一次。
        #expect(LinkIconCache.posterIcon(for: 4, icon: data, style: style, size: 50) === image)
    }

    @Test func iconBitmapsAreSharpOnRetinaEvenWhenOnlyA1xScreenWasConnected() {
        // 位图画好后一直缓存：只接着 1x 显示器时也按 2x 画，之后接上 Retina 屏不发虚（#19）。
        #expect(AppIconCache.bitmapScale(screenScales: [1]) == 2)
        #expect(AppIconCache.bitmapScale(screenScales: []) == 2)
        #expect(AppIconCache.bitmapScale(screenScales: [1, 2]) == 2)
        #expect(AppIconCache.bitmapScale(screenScales: [3]) == 3)
    }

    private func headline(_ link: String) -> String? {
        LinkText.headline(from: URL(string: link)!)
    }

    @Test func headlinesAreReadFromTheAddress() {
        #expect(headline("https://github.com/swiftlang/swift") == "swiftlang / swift")
        #expect(headline("https://zh.wikipedia.org/wiki/Swift") == "Swift")
        #expect(headline("https://www.apple.com.cn/iphone/") == "iphone")
        #expect(headline("https://news.example.com/2026/10/how-to-build-a-mac-app.html") == "how to build a mac app")
        #expect(headline("https://www.reddit.com/r/apple/comments/1o6ky4f/") == "apple")
        #expect(headline("https://github.com/swiftlang/swift/issues/123") == "swiftlang / swift")
        #expect(headline("https://www.youtube.com/watch?v=dQw4w9WgXcQ") == nil)
        #expect(headline("https://example.com/") == nil)
    }

    @Test func pageTitlesWinAndTheSiteDropsWWW() {
        var item = ClipItem(id: 9, kind: .link, preview: "https://www.github.com/swiftlang/swift", textLength: 0,
                            thumbnail: nil, sourceBundleID: nil, sourceName: nil, createdAt: Date())
        #expect(LinkText(item: item) == LinkText(headline: "swiftlang / swift", site: "github.com"))
        item.linkTitle = "GitHub - swiftlang/swift"
        #expect(LinkText(item: item).headline == "GitHub - swiftlang/swift")
        item.preview = "https://www.youtube.com/watch?v=x"
        item.linkTitle = ""
        #expect(LinkText(item: item).headline == "youtube.com")
    }
}
