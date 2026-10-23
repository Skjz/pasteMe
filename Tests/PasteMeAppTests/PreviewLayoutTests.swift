import AppKit
import Testing
@testable import PasteMeApp
import PasteMeCore

/// 预览窗口按内容定大小：网页用整块地方，图片按比例不放大，文本按内容的高度，文件按类型；都加上顶上的窄栏。
@MainActor
@Suite final class PreviewLayoutTests {
    let available = CGSize(width: 1200, height: 600)
    let bar = PreviewLayout.barHeight
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewLayoutTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func pagesTakeAllTheRoomAbovePanel() {
        #expect(PreviewLayout.size(for: .page, available: available) == available)
    }

    @Test func roomIsEightyPercentOfTheScreenAtMost() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let panel = NSRect(x: 0, y: 0, width: 1512, height: 330)
        let room = PreviewLayout.available(above: panel, in: visible)
        #expect(abs(room.width - 1512 * 0.8) < 0.01)
        #expect(abs(room.height - (944 - 330 - 24)) < 0.01)
    }

    @Test func imagesKeepTheirShapeBelowTheBarAndAreNotEnlarged() {
        // 大图缩进窄栏下面剩下的 1200×560：宽高比不变。
        #expect(PreviewLayout.size(for: .fitted(CGSize(width: 2400, height: 1200), extra: 0), available: available)
            == CGSize(width: 1120, height: 560 + bar))
        // 竖长的图缩到 280 宽，窗口最窄 360，图在里面居中。
        #expect(PreviewLayout.size(for: .fitted(CGSize(width: 1000, height: 2000), extra: 0), available: available)
            == CGSize(width: 360, height: 560 + bar))
        // 小图按原大小，窗口不小于最小尺寸。
        #expect(PreviewLayout.size(for: .fitted(CGSize(width: 500, height: 400), extra: 0), available: available)
            == CGSize(width: 500, height: 400 + bar))
        #expect(PreviewLayout.size(for: .fitted(CGSize(width: 64, height: 64), extra: 0), available: available) == PreviewLayout.minSize)
    }

    @Test func recognizedTextGetsRoomBelowTheImage() {
        let extra = PreviewLayout.recognizedTextHeight
        let size = PreviewLayout.size(for: .fitted(CGSize(width: 2400, height: 1200), extra: extra), available: available)
        #expect(size.height == available.height)
        #expect(abs(size.width - 2 * (available.height - bar - extra)) <= 1)
    }

    @Test func textIsAsTallAsItsContent() {
        let short = PreviewLayout.size(for: .text(height: 40), available: available)
        #expect(short == CGSize(width: PreviewLayout.textWidth, height: PreviewLayout.minSize.height))
        #expect(PreviewLayout.size(for: .text(height: 300), available: available).height == 300 + bar)
        #expect(PreviewLayout.size(for: .text(height: .greatestFiniteMagnitude), available: available).height == available.height)
    }

    @Test func measuredTextGrowsWithItsLines() {
        let font: [NSAttributedString.Key: Any] = [.font: PreviewLayout.textFont]
        let one = PreviewLayout.height(of: NSAttributedString(string: "一行", attributes: font))
        let ten = PreviewLayout.height(of: NSAttributedString(string: Array(repeating: "一行", count: 10).joined(separator: "\n"), attributes: font))
        // 多出来的 9 行，每行和第一行一样高。
        let line = one - PreviewLayout.textInset.height * 2
        #expect(abs((ten - one) - line * 9) < 1)
        let huge = NSAttributedString(string: String(repeating: "a", count: PreviewLayout.measuredLength + 1), attributes: font)
        #expect(PreviewLayout.height(of: huge) == .greatestFiniteMagnitude)
    }

    // MARK: 文件按类型

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test func shortScriptsGetASmallWindow() throws {
        let script = try file("run.sh", Data("#!/bin/sh\necho hello\n".utf8))
        guard case .text(let height) = PreviewLayout.content(forFileAt: script) else {
            Issue.record("脚本应该按文本定高度")
            return
        }
        #expect(PreviewLayout.size(for: .text(height: height), available: available).height == PreviewLayout.minSize.height)
    }

    @Test func imageFilesUseTheirPixelSize() throws {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let png = try file("shot.png", try #require(rep.representation(using: .png, properties: [:])))
        #expect(PreviewLayout.content(forFileAt: png) == .fitted(CGSize(width: 300, height: 200), extra: 0))
    }

    @Test func foldersGetAFixedSmallWindowAndOtherFilesTheWholeRoom() throws {
        let folder = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(PreviewLayout.content(forFileAt: folder) == .fitted(PreviewLayout.folderSize, extra: 0))
        let pdf = try file("doc.pdf", Data("%PDF-1.4\n".utf8))
        #expect(PreviewLayout.content(forFileAt: pdf) == .page)
    }
}
