import Foundation
import Testing
@testable import PasteMeCore

/// 编辑条目的文字和标题，以及改完后和其他条目内容相同时怎么合并（#10）。
@Suite struct ClipEditingTests {
    let store: ClipStore

    init() throws {
        store = try ClipStore(path: ":memory:")
    }

    @Test func editedTextIsUsedForSearchAndPaste() throws {
        let id = try store.insert(ClipContent(kind: .text, text: "draft", rtf: Data([1])), source: nil)

        #expect(try store.updateText("final version", rtf: Data([2]), id: id))

        #expect(try store.content(id: id) == ClipContent(kind: .text, text: "final version", rtf: Data([2])))
        #expect(try store.items(matching: ClipQuery(text: "final")).map(\.id) == [id])
        #expect(try store.items(matching: ClipQuery(text: "draft")).isEmpty)
        // 改过的内容再复制一次，是同一个条目。
        #expect(try store.insert(ClipContent(kind: .text, text: "final version"), source: nil) == id)
    }

    @Test func emptyTextAndOtherKindsAreNotChanged() throws {
        let text = try store.insert(ClipContent(kind: .text, text: "keep"), source: nil)
        let image = try store.insert(ClipContent(kind: .image, image: try #require(ClipStoreTests.makePNG(width: 2, height: 2))), source: nil)

        #expect(try !store.updateText("  \n", rtf: nil, id: text))
        #expect(try !store.updateText("x", rtf: nil, id: image))
        #expect(try !store.updateText("x", rtf: nil, id: 42))
        #expect(try store.content(id: text)?.text == "keep")
    }

    @Test func editingIntoAnotherEntryMergesThemKeepingTheNewerTime() throws {
        let board = try store.createPinboard(name: "工作", color: .blue)
        let newer = try store.insert(ClipContent(kind: .text, text: "hello"), source: nil, at: Date(timeIntervalSince1970: 9))
        let edited = try store.insert(ClipContent(kind: .text, text: "helo"), source: nil, at: Date(timeIntervalSince1970: 1))
        try store.setTitle("问候", id: newer)
        try store.pin(newer, to: board.id)

        #expect(try store.updateText("hello", rtf: nil, id: edited))

        let items = try store.items()
        #expect(items.map(\.id) == [edited])
        #expect(items.first?.createdAt == Date(timeIntervalSince1970: 9))
        // 这条没有标题，用另一条的；另一条所在的 Pinboard 也算上。
        #expect(items.first?.title == "问候")
        #expect(items.first?.pinboardIDs == [board.id])
    }

    @Test func mergingKeepsTheEditedEntrysOwnTitle() throws {
        let other = try store.insert(ClipContent(kind: .text, text: "b"), source: nil, at: Date(timeIntervalSince1970: 1))
        let edited = try store.insert(ClipContent(kind: .text, text: "a"), source: nil, at: Date(timeIntervalSince1970: 2))
        try store.setTitle("别人的", id: other)
        try store.setTitle("自己的", id: edited)

        try store.updateText("b", rtf: nil, id: edited)

        #expect(try store.items().map(\.title) == ["自己的"])
        #expect(try store.items().first?.createdAt == Date(timeIntervalSince1970: 2))
    }

    @Test func editingALinkKeepsItALinkUnlessItStopsBeingOne() throws {
        let id = try store.insert(ClipContent(kind: .link, text: "https://a.example"), source: nil)
        try store.setLinkPreview(LinkPreview(title: "A", image: Data([1]), icon: Data([2])), id: id)

        try store.updateText(" https://b.example \n", rtf: nil, id: id)
        var item = try #require(try store.item(id: id))
        #expect(item.kind == .link && item.preview == "https://b.example")
        // 网址变了，原来的预览作废，可以重新获取。
        #expect(item.linkTitle == nil && item.thumbnail == nil && item.linkIcon == nil)
        #expect(try store.linkPreviewURL(id: id) != nil)

        try store.updateText("not a link", rtf: Data([1]), id: id)
        item = try #require(try store.item(id: id))
        #expect(item.kind == .text)
        #expect(try store.content(id: id)?.rtf == Data([1]))
    }

    @Test func titlesAreTrimmedSearchableAndRemovable() throws {
        let id = try store.insert(ClipContent(kind: .text, text: "SELECT * FROM t"), source: nil)

        try store.setTitle("  查询模板 ", id: id)
        #expect(try store.item(id: id)?.title == "查询模板")
        #expect(try store.items(matching: ClipQuery(text: "模板")).map(\.id) == [id])

        try store.setTitle(" ", id: id)
        #expect(try store.item(id: id)?.title == nil)
    }

    @Test func copyingTheSameContentAgainKeepsTheTitle() throws {
        let id = try store.insert(ClipContent(kind: .text, text: "x"), source: nil, at: Date(timeIntervalSince1970: 1))
        try store.setTitle("标题", id: id)

        try store.insert(ClipContent(kind: .text, text: "x"), source: nil, at: Date(timeIntervalSince1970: 2))

        #expect(try store.item(id: id)?.title == "标题")
    }
}
