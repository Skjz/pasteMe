import Foundation
import Testing
@testable import PasteMeCore

/// 隔空投送的计划、临时文件名和临时目录清理（#68）。
@Suite final class AirDropTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasteMeTests.AirDrop.\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func plansCoverLinksTextImagesAndFiles() {
        let link = AirDropPlan.make(kind: .link, text: "  https://example.com/a  ")
        #expect(link == AirDropPlan(items: [.url(URL(string: "https://example.com/a")!)]))

        let text = AirDropPlan.make(kind: .text, text: "第一行\n第二行")
        #expect(text == AirDropPlan(items: [.temporaryFile(name: "第一行.txt", data: Data("第一行\n第二行".utf8))]))

        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let image = AirDropPlan.make(kind: .image, text: nil, image: png)
        #expect(image == AirDropPlan(items: [.temporaryFile(name: "PasteMe 图片.png", data: png)]))
        let titledImage = AirDropPlan.make(kind: .image, text: nil, image: png, title: "发票截图")
        #expect(titledImage == AirDropPlan(items: [.temporaryFile(name: "发票截图.png", data: png)]))

        let files = AirDropPlan.make(kind: .file, text: "/a/doc.pdf\n/a/folder") { _ in true }
        #expect(files == AirDropPlan(items: [
            .url(URL(fileURLWithPath: "/a/doc.pdf")),
            .url(URL(fileURLWithPath: "/a/folder")),
        ]))
    }

    @Test func fileNamesUseTitleOrFirstLineTruncateAndStripIllegalCharacters() {
        func name(_ title: String?, _ text: String) -> String {
            AirDropPlan.fileName(title: title, firstLineOf: text, fallback: AirDropPlan.defaultTextName, pathExtension: "txt")
        }

        #expect(name("会议纪要", "其他正文") == "会议纪要.txt")
        #expect(name("notes.txt", "body") == "notes.txt")
        #expect(name(nil, "  a/b:c  \n第二行") == "a b c.txt")
        #expect(name(nil, ".hidden") == "hidden.txt")
        #expect(name(nil, String(repeating: "字", count: 45)) == String(repeating: "字", count: 30) + ".txt")
        #expect(name("   ", "\n\n第三行才是文字") == "第三行才是文字.txt")
        #expect(name(nil, "") == "PasteMe 文本.txt")
        #expect(name(nil, " / : ... ") == "PasteMe 文本.txt")
    }

    @Test func missingFilesAreCountedOrDisableThePlan() {
        let partial = AirDropPlan.make(kind: .file, text: "/gone.txt\n/kept.txt\n/missing.png") { $0 == "/kept.txt" }
        #expect(partial.items == [.url(URL(fileURLWithPath: "/kept.txt"))])
        #expect(partial.missing == 2)
        #expect(partial.unavailableReason == nil)

        let allGone = AirDropPlan.make(kind: .file, text: "/gone.txt\n/missing.png") { _ in false }
        #expect(allGone.items.isEmpty)
        #expect(allGone.missing == 2)
        #expect(allGone.unavailableReason == "文件已经不在了")
    }

    @Test func temporaryFilesAreRemovedAfterFinishAndOnStartup() throws {
        let files = AirDropFiles(directory: directory)
        let plan = AirDropPlan.make(kind: .text, text: "Hello AirDrop", title: "问候")
        let prepared = try files.prepare(plan.items)

        let fileURL = try #require(prepared.urls.first)
        #expect(fileURL.lastPathComponent == "问候.txt")
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "Hello AirDrop")

        prepared.cleanUp()
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(remaining.isEmpty)

        // 模拟上次异常退出留下的文件，启动时 `removeAll` 全部清掉。
        let leftover = try files.prepare(plan.items)
        #expect(FileManager.default.fileExists(atPath: leftover.urls[0].path))
        files.removeAll()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
