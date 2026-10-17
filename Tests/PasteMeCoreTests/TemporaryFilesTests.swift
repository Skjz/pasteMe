import AppKit
import Foundation
import Testing
@testable import PasteMeCore

/// 以文件粘贴、拖出图片时生成的 PNG 文件，以及它们的清理（#12）。
@MainActor
@Suite final class TemporaryFilesTests {
    let directory: URL
    let files: TemporaryFiles
    let store: ClipStore
    let pasteboard = FakePasteboard()
    let png: Data

    init() throws {
        directory = try ClipStoreTests.makeTempDirectory()
        files = TemporaryFiles(directory: directory)
        store = try ClipStore(path: ":memory:")
        png = try #require(ClipStoreTests.makePNG(width: 4, height: 4))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func paster(imagesAsFiles: Bool = false) -> Paster {
        Paster(store: store, pasteboard: pasteboard, keystroke: FakeKeystroke(), files: files) { imagesAsFiles }
    }

    @Test func imageFilesAreNamedAfterTheCopyTime() throws {
        let copiedAt = try #require(DateComponents(
            calendar: .current, year: 2026, month: 10, day: 16, hour: 14, minute: 41, second: 55
        ).date)

        let url = try files.imageFile(png, id: 7, copiedAt: copiedAt)

        #expect(url.lastPathComponent == "PasteMe 2026-10-16 14.41.55.png")
        #expect(try Data(contentsOf: url) == png)
        // 同一秒复制的另一张图片不会覆盖它。
        #expect(try files.imageFile(png + [0], id: 8, copiedAt: copiedAt) != url)
    }

    @Test func pastingAsFileAttachesAPNGOnlyToImages() throws {
        let image = try store.insert(ClipContent(kind: .image, image: png), source: nil)
        let text = try store.insert(ClipContent(kind: .text, text: "x"), source: nil)
        let paster = paster()

        try paster.copyToPasteboard(image, as: .file)
        try paster.copyToPasteboard(text, as: .file)
        try paster.copyToPasteboard(image, as: .original)

        #expect(pasteboard.written.map(\.kind) == [.image, .text, .image])
        let file = try #require(pasteboard.files[0])
        #expect(try Data(contentsOf: file) == png)
        #expect(pasteboard.files[1] == nil && pasteboard.files[2] == nil)
    }

    @Test func theSettingMakesEveryImagePasteAttachAFile() throws {
        let image = try store.insert(ClipContent(kind: .image, image: png), source: nil)

        try paster(imagesAsFiles: true).copyToPasteboard(image)
        try paster(imagesAsFiles: true).copyToPasteboard(image, as: .plainText)

        #expect(pasteboard.files.map { $0 != nil } == [true, false])
    }

    @Test func draggingAnImageOffersTheDataAndTheFile() throws {
        let image = try store.insert(ClipContent(kind: .image, image: png), source: nil)

        let writers = try paster().draggingWriters(for: image)

        let item = try #require(writers.first as? NSPasteboardItem)
        #expect(item.types.contains(.png) && item.types.contains(.tiff) && item.types.contains(.fileURL))
        let url = try #require(item.string(forType: .fileURL).flatMap(URL.init(string:)))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func draggingFilesSkipsMissingOnesAndFailsWhenAllAreGone() throws {
        let present = directory.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: present)
        let missing = directory.appendingPathComponent("gone.txt")
        let both = try store.insert(ClipContent(kind: .file, text: present.path + "\n" + missing.path), source: nil)
        let gone = try store.insert(ClipContent(kind: .file, text: missing.path), source: nil)

        let writers = try paster().draggingWriters(for: both)
        #expect((writers as? [NSURL])?.map(\.path) == [present.path])
        #expect(throws: PasteError.filesMissing) { try self.paster().draggingWriters(for: gone) }
    }

    @Test func filesNotUsedForADayAreRemoved() throws {
        let old = try files.imageFile(png, id: 1, copiedAt: Date())
        let fresh = try files.imageFile(png, id: 2, copiedAt: Date())
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-2 * 24 * 60 * 60)], ofItemAtPath: old.path
        )

        files.removeExpired()

        #expect(!FileManager.default.fileExists(atPath: old.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func usingAFileAgainKeepsItForAnotherDay() throws {
        let copiedAt = Date(timeIntervalSince1970: 1_000)
        let url = try files.imageFile(png, id: 1, copiedAt: copiedAt)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-2 * 24 * 60 * 60)], ofItemAtPath: url.path
        )

        #expect(try files.imageFile(png, id: 1, copiedAt: copiedAt) == url)
        files.removeExpired()

        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
