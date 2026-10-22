import AppKit
import Foundation
import Testing
@testable import PasteMeCore

/// 文本粘贴或拖到访达时生成 .txt 文件（#36）。
@MainActor
@Suite final class TextFileTests {
    let directory: URL
    let files: TemporaryFiles
    let store: ClipStore
    let pasteboard = FakePasteboard()
    let finder = TargetApp(bundleID: TextFile.finderBundleID, name: "访达")
    let copiedAt = Date(timeIntervalSince1970: 1_760_597_315)

    init() throws {
        directory = try ClipStoreTests.makeTempDirectory()
        files = TemporaryFiles(directory: directory)
        store = try ClipStore(path: ":memory:")
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private var paster: Paster {
        Paster(store: store, pasteboard: pasteboard, keystroke: FakeKeystroke(), files: files)
    }

    @Test func pastingTextIntoFinderAttachesATextFile() throws {
        let id = try store.insert(ClipContent(kind: .text, text: "第一行\n第二行"), source: nil, at: copiedAt)

        #expect(try paster.paste(id, into: finder) == .pasted)

        #expect(pasteboard.written == [ClipContent(kind: .text, text: "第一行\n第二行")])
        let file = try #require(pasteboard.files.first ?? nil)
        #expect(file.lastPathComponent == "第一行.txt")
        #expect(try String(contentsOf: file, encoding: .utf8) == "第一行\n第二行")
        #expect(try Data(contentsOf: file).prefix(3) != Data([0xEF, 0xBB, 0xBF]))
    }

    @Test func otherAppsOnlyGetTheText() throws {
        let id = try store.insert(ClipContent(kind: .text, text: "hello"), source: nil)
        let link = try store.insert(ClipContent(kind: .link, text: "https://example.com"), source: nil)

        _ = try paster.paste(id, into: TargetApp(bundleID: "com.apple.Notes", name: "备忘录"))
        _ = try paster.paste(id, into: nil)
        _ = try paster.paste(link, into: finder)

        #expect(pasteboard.files == [nil, nil, nil])
    }

    @Test func theTitleNamesTheFileAndEditingReplacesIt() throws {
        let id = try store.insert(ClipContent(kind: .text, text: "hello"), source: nil, at: copiedAt)
        try store.setTitle("问候", id: id)
        _ = try paster.paste(id, into: finder)
        let first = try #require(pasteboard.files.last ?? nil)
        #expect(first.lastPathComponent == "问候.txt")

        try store.setTitle(nil, id: id)
        _ = try paster.paste(id, into: finder)
        let second = try #require(pasteboard.files.last ?? nil)
        #expect(second.lastPathComponent == "hello.txt")
        #expect(!FileManager.default.fileExists(atPath: first.path))
    }

    @Test func fileNames() {
        func name(_ title: String?, _ text: String) -> String {
            TextFile.name(title: title, text: text, copiedAt: copiedAt)
        }
        #expect(name("报销", "x") == "报销")
        #expect(name(nil, "  a/b:c  \nsecond") == "a b c")
        #expect(name(nil, ".hidden") == "hidden")
        #expect(name(nil, String(repeating: "长", count: 50)) == String(repeating: "长", count: 40))
        #expect(name(" ", "\n\n第三行") == "第三行")
        #expect(name(nil, "...") == "PasteMe \(TemporaryFiles.timestamp(copiedAt))")
        #expect(name(nil, "") == "PasteMe \(TemporaryFiles.timestamp(copiedAt))")
    }

    @Test func draggingTextOffersTheTextAndAFilePromise() throws {
        let rtf = Data("{\\rtf1 bold}".utf8)
        let id = try store.insert(ClipContent(kind: .text, text: "bold", rtf: rtf), source: nil, at: copiedAt)

        let promise = try #require(paster.draggingWriters(for: id).first as? TextFilePromise)
        let types = promise.writableTypes(for: NSPasteboard(name: .drag))
        #expect(types.contains(.string) && types.contains(.rtf))
        #expect(promise.pasteboardPropertyList(forType: .string) as? String == "bold")
        #expect(promise.pasteboardPropertyList(forType: .rtf) as? Data == rtf)
        #expect(promise.filePromiseProvider(promise, fileNameForType: promise.fileType) == "bold.txt")

        let url = directory.appendingPathComponent("dropped.txt")
        var failure: Error?
        promise.filePromiseProvider(promise, writePromiseTo: url) { failure = $0 }
        #expect(failure == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "bold")
    }
}
