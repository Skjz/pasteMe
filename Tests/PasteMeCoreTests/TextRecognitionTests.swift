import AppKit
import Foundation
import Testing
@testable import PasteMeCore

/// 记下要识别哪些图片，按预设返回文字。
final class FakeRecognizer: TextRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _inputs: [TextRecognitionInput] = []
    private let result: @Sendable (TextRecognitionInput) -> String

    init(result: @escaping @Sendable (TextRecognitionInput) -> String) {
        self.result = result
    }

    var inputs: [TextRecognitionInput] { lock.withLock { _inputs } }

    func recognizeText(in input: TextRecognitionInput) async -> String {
        lock.withLock { _inputs.append(input) }
        return result(input)
    }
}

/// 图片中的文字：入库、搜索、补做、后台识别（#5）。
@MainActor
@Suite struct TextRecognitionTests {
    let store: ClipStore
    let png: Data

    init() throws {
        store = try ClipStore(path: ":memory:")
        png = try #require(ClipStoreTests.makePNG(width: 8, height: 8))
    }

    private func insertImage(_ seed: UInt8, at second: Double = 1) throws -> Int64 {
        // 每张图片的内容不同，才不会被当成同一个条目。
        var data = png
        data.append(seed)
        return try store.insert(ClipContent(kind: .image, image: data), source: nil, at: Date(timeIntervalSince1970: second))
    }

    @Test func searchFindsTextInsideImages() throws {
        let id = try insertImage(1)
        try store.insert(ClipContent(kind: .text, text: "unrelated"), source: nil)

        try store.setRecognizedText("增值税发票\nInvoice No. 42", id: id)

        let hits = try store.items(matching: ClipQuery(text: "发票"))
        #expect(hits.map(\.id) == [id])
        #expect(hits.first?.recognizedText == "增值税发票\nInvoice No. 42")
        #expect(try store.items(matching: ClipQuery(text: "invoice")).map(\.id) == [id])
    }

    @Test func onlyUnrecognizedImagesArePending() throws {
        let done = try insertImage(1, at: 1)
        let empty = try insertImage(2, at: 2)
        let waiting = try insertImage(3, at: 3)
        try store.insert(ClipContent(kind: .text, text: "text"), source: nil)
        try store.insert(ClipContent(kind: .file, text: "/tmp/not-an-image.txt"), source: nil)

        try store.setRecognizedText("hello", id: done)
        // 识别过但没有文字：存空字符串，以后不再识别。
        try store.setRecognizedText("", id: empty)

        #expect(try store.idsPendingTextRecognition() == [waiting])
        #expect(try store.textRecognitionInput(id: empty) == nil)
        #expect(try store.textRecognitionInput(id: waiting) != nil)
    }

    @Test func imageFilesAreRecognizedFromTheFileWithThumbnailAsFallback() throws {
        let dir = try ClipStoreTests.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shot.png")
        try png.write(to: url)
        let id = try store.insert(ClipContent(kind: .file, text: url.path), source: nil)

        guard case .imageFile(let fileURL, let fallback)? = try store.textRecognitionInput(id: id) else {
            Issue.record("图片文件应当可以识别")
            return
        }
        #expect(fileURL == url)
        #expect(!fallback.isEmpty)
    }

    @Test func undoingDeleteKeepsRecognizedText() throws {
        let id = try insertImage(1)
        try store.setRecognizedText("收据", id: id)

        let deleted = try #require(try store.delete(id: id))
        try store.restore(deleted)

        #expect(try store.items(matching: ClipQuery(text: "收据")).map(\.id) == [id])
    }

    @Test func queueRecognizesNewImagesAndSkipsOtherKinds() async throws {
        let recognizer = FakeRecognizer { _ in "会议纪要" }
        let queue = EnrichmentQueue(store: store, recognizer: recognizer, backfillPause: .zero)
        var enriched: [Int64] = []
        queue.onEnriched = { enriched.append($0) }
        let recorder = Recorder(store: store, enrichment: queue)

        let image = try #require(try recorder.record(ClipContent(kind: .image, image: png), from: nil))
        try recorder.record(ClipContent(kind: .text, text: "plain"), from: nil)
        await queue.waitUntilIdle()

        #expect(enriched == [image])
        #expect(recognizer.inputs == [.imageData(png)])
        #expect(try store.items(matching: ClipQuery(text: "纪要")).map(\.id) == [image])
    }

    @Test func imagesWithoutTextAreNotRecognizedAgain() async throws {
        let recognizer = FakeRecognizer { _ in "" }
        let queue = EnrichmentQueue(store: store, recognizer: recognizer, backfillPause: .zero)
        let id = try insertImage(1)

        queue.enqueue(id)
        await queue.waitUntilIdle()
        queue.backfill()
        queue.enqueue(id)
        await queue.waitUntilIdle()

        #expect(recognizer.inputs.count == 1)
        #expect(try store.items().first?.recognizedText == "")
    }

    @Test func backfillProcessesOldImagesNewestFirst() async throws {
        let older = try insertImage(1, at: 1)
        let newer = try insertImage(2, at: 2)
        let queue = EnrichmentQueue(store: store, recognizer: FakeRecognizer { _ in "x" }, backfillPause: .zero)
        var enriched: [Int64] = []
        queue.onEnriched = { enriched.append($0) }

        queue.backfill()
        await queue.waitUntilIdle()

        #expect(enriched == [newer, older])
        #expect(try store.idsPendingTextRecognition().isEmpty)
    }

    /// 真的调用 Vision：图片里画上中英文，确认能识别出来。
    @Test func visionRecognizesChineseAndEnglish() async throws {
        let image = try #require(Self.renderText("剪贴板发票 Invoice 2026"))
        let text = await VisionTextRecognizer().recognizeText(in: .imageData(image))

        #expect(text.contains("发票"))
        #expect(text.contains("Invoice"))
    }

    @Test func visionReturnsEmptyForBlankOrBrokenImages() async throws {
        #expect(await VisionTextRecognizer().recognizeText(in: .imageData(png)) == "")
        #expect(await VisionTextRecognizer().recognizeText(in: .imageData(Data("not an image".utf8))) == "")
    }

    static func renderText(_ string: String) -> Data? {
        let size = NSSize(width: 900, height: 160)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (string as NSString).draw(at: NSPoint(x: 30, y: 50), withAttributes: [
            .font: NSFont.systemFont(ofSize: 56),
            .foregroundColor: NSColor.black,
        ])
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
