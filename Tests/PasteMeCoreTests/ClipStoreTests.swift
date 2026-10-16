import CoreGraphics
import Foundation
import Testing
@testable import PasteMeCore

@Suite struct ClipStoreTests {
    let store: ClipStore

    init() throws {
        store = try ClipStore(path: ":memory:")
    }

    @Test func itemsAreNewestFirst() throws {
        try store.insert(ClipContent(kind: .text, text: "first"), source: nil, at: Date(timeIntervalSince1970: 1))
        try store.insert(ClipContent(kind: .text, text: "second"), source: nil, at: Date(timeIntervalSince1970: 2))

        #expect(try store.items().map(\.preview) == ["second", "first"])
    }

    @Test func copyingSameContentAgainMovesItToTopWithoutDuplicating() throws {
        let first = try store.insert(ClipContent(kind: .text, text: "a"), source: nil, at: Date(timeIntervalSince1970: 1))
        try store.insert(ClipContent(kind: .text, text: "b"), source: nil, at: Date(timeIntervalSince1970: 2))
        let again = try store.insert(
            ClipContent(kind: .text, text: "a"),
            source: ClipSource(bundleID: "com.apple.Notes", name: "Notes"),
            at: Date(timeIntervalSince1970: 3)
        )

        #expect(again == first)
        let items = try store.items()
        #expect(items.map(\.preview) == ["a", "b"])
        #expect(items.first?.sourceName == "Notes")
    }

    @Test func contentRoundTripsRichTextAndImage() throws {
        let png = try #require(Self.makePNG(width: 4, height: 4))
        let textID = try store.insert(ClipContent(kind: .text, text: "bold", rtf: Data("{\\rtf1 bold}".utf8)), source: nil)
        let imageID = try store.insert(ClipContent(kind: .image, image: png), source: nil)

        #expect(try store.content(id: textID)?.rtf == Data("{\\rtf1 bold}".utf8))
        #expect(try store.content(id: imageID)?.image == png)
        #expect(try store.items().first { $0.id == imageID }?.thumbnail != nil)
    }

    @Test func imageFileGetsThumbnailButOtherFilesDoNot() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pngURL = dir.appendingPathComponent("shot.png")
        let textURL = dir.appendingPathComponent("notes.txt")
        try #require(Self.makePNG(width: 8, height: 8)).write(to: pngURL)
        try Data("hi".utf8).write(to: textURL)

        let imageFileID = try store.insert(ClipContent(kind: .file, text: pngURL.path), source: nil)
        let textFileID = try store.insert(ClipContent(kind: .file, text: textURL.path), source: nil)

        let items = try store.items()
        #expect(items.first { $0.id == imageFileID }?.thumbnail != nil)
        #expect(items.first { $0.id == textFileID }?.thumbnail == nil)
    }

    @Test func copyingAgainFillsMissingThumbnail() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pngURL = dir.appendingPathComponent("later.png")
        let content = ClipContent(kind: .file, text: pngURL.path)

        // 第一次复制时文件还不存在（或不可读），没有缩略图。
        let id = try store.insert(content, source: nil)
        #expect(try store.items().first?.thumbnail == nil)

        try #require(Self.makePNG(width: 8, height: 8)).write(to: pngURL)
        #expect(try store.insert(content, source: nil) == id)
        #expect(try store.items().first?.thumbnail != nil)
    }

    @Test func touchMovesItemToTop() throws {
        let old = try store.insert(ClipContent(kind: .text, text: "old"), source: nil, at: Date(timeIntervalSince1970: 1))
        try store.insert(ClipContent(kind: .text, text: "new"), source: nil, at: Date(timeIntervalSince1970: 2))

        try store.touch(id: old, at: Date(timeIntervalSince1970: 3))

        #expect(try store.items().first?.id == old)
    }

    @Test func deleteRemovesItems() throws {
        let id = try store.insert(ClipContent(kind: .text, text: "x"), source: nil)
        try store.insert(ClipContent(kind: .text, text: "y"), source: nil)

        try store.delete(id: id)
        #expect(try store.count() == 1)

        try store.deleteAll()
        #expect(try store.count() == 0)
    }

    @Test func textLengthCountsFullTextBeyondPreview() throws {
        let long = String(repeating: "a", count: ClipStore.previewLength + 10)
        try store.insert(ClipContent(kind: .text, text: long), source: nil)

        let item = try #require(try store.items().first)
        #expect(item.textLength == long.count)
        #expect(item.preview?.count == ClipStore.previewLength)
    }

    static func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func makePNG(width: Int, height: Int) -> Data? {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage().flatMap(Thumbnailer.pngData(from:))
    }
}
