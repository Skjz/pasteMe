import AppKit
import Testing
@testable import PasteMeCore

@Suite struct PasteboardCodecTests {
    let pasteboard = NSPasteboard.withUniqueName()

    @Test func plainStringIsText() {
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)

        #expect(PasteboardCodec.read(pasteboard) == ClipContent(kind: .text, text: "hello"))
    }

    @Test func singleWebURLIsLink() {
        pasteboard.clearContents()
        pasteboard.setString("  https://pasteapp.io/use-cases\n", forType: .string)

        #expect(PasteboardCodec.read(pasteboard) == ClipContent(kind: .link, text: "https://pasteapp.io/use-cases"))
    }

    @Test func textContainingURLIsNotLink() {
        #expect(!PasteboardCodec.isWebLink("see https://example.com"))
        #expect(!PasteboardCodec.isWebLink("ftp://example.com"))
        #expect(PasteboardCodec.isWebLink("http://example.com/a?b=c"))
    }

    @Test func imageWithLinkIsImage() throws {
        let png = try #require(ClipStoreTests.makePNG(width: 2, height: 2))
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        pasteboard.setString("https://example.com/cat.png", forType: .string)

        #expect(PasteboardCodec.read(pasteboard)?.kind == .image)
    }

    @Test func imageWithOrdinaryTextIsText() throws {
        // 例如从表格软件复制单元格：同时带有文字和渲染出的图片。
        let png = try #require(ClipStoreTests.makePNG(width: 2, height: 2))
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        pasteboard.setString("A1\tB1", forType: .string)

        #expect(PasteboardCodec.read(pasteboard)?.kind == .text)
    }

    @Test func fileURLsAreFiles() {
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")] as [NSURL])

        let content = PasteboardCodec.read(pasteboard)
        #expect(content?.kind == .file)
        #expect(content?.fileURLs.map(\.path) == ["/tmp/a.txt", "/tmp/b.txt"])
    }

    @Test func concealedContentIsIgnored() {
        pasteboard.clearContents()
        pasteboard.setString("secret", forType: .string)
        pasteboard.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))

        #expect(PasteboardCodec.shouldIgnore(pasteboard))
    }

    @Test func writeThenReadRoundTripsAndMarksOwnWrite() {
        let content = ClipContent(kind: .text, text: "round trip")
        PasteboardCodec.write(content, to: pasteboard)

        #expect(PasteboardCodec.isOwnWrite(pasteboard))
        #expect(PasteboardCodec.read(pasteboard) == content)
    }

    @Test func imageWrittenWithAFileOffersBothAndIsMarkedAsOwn() throws {
        let png = try #require(ClipStoreTests.makePNG(width: 2, height: 2))
        let file = URL(fileURLWithPath: "/tmp/PasteMe 2026-10-16 14.41.55.png")

        PasteboardCodec.write(ClipContent(kind: .image, image: png), attachingFile: file, to: pasteboard)

        let types = pasteboard.types ?? []
        #expect(types.contains(.png) && types.contains(.tiff) && types.contains(.fileURL))
        #expect(pasteboard.string(forType: .fileURL) == file.absoluteString)
        #expect(PasteboardCodec.isOwnWrite(pasteboard))
    }

    @Test func writtenTextAndFilesAreStillMarkedAsOwn() {
        PasteboardCodec.write(ClipContent(kind: .text, text: "hi", rtf: Data("{\\rtf1 hi}".utf8)), to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "hi")
        #expect(pasteboard.data(forType: .rtf) != nil)
        #expect(PasteboardCodec.isOwnWrite(pasteboard))

        PasteboardCodec.write(ClipContent(kind: .file, text: "/tmp/a\n/tmp/b"), to: pasteboard)
        #expect(pasteboard.pasteboardItems?.count == 2)
        #expect(PasteboardCodec.isOwnWrite(pasteboard))
    }
}
