import Foundation
import Testing
@testable import PasteMeCore

@MainActor
@Suite struct PasterTests {
    let store: ClipStore
    let pasteboard = FakePasteboard()
    let keystroke = FakeKeystroke()
    let paster: Paster

    init() throws {
        store = try ClipStore(path: ":memory:")
        paster = Paster(store: store, pasteboard: pasteboard, keystroke: keystroke)
    }

    @Test func originalPasteKeepsRichText() throws {
        let rtf = Data("{\\rtf1 bold}".utf8)
        let id = try store.insert(ClipContent(kind: .text, text: "bold", rtf: rtf), source: nil)

        #expect(try paster.paste(id, as: .original, into: nil) == .pasted)
        #expect(pasteboard.written == [ClipContent(kind: .text, text: "bold", rtf: rtf)])
    }

    @Test func plainTextPasteDropsRichText() throws {
        let id = try store.insert(ClipContent(kind: .text, text: "bold", rtf: Data("{\\rtf1 bold}".utf8)), source: nil)

        _ = try paster.paste(id, as: .plainText, into: nil)

        #expect(pasteboard.written == [ClipContent(kind: .text, text: "bold")])
    }

    @Test func pastedItemMovesToTopOfHistory() throws {
        let old = try store.insert(ClipContent(kind: .text, text: "old"), source: nil, at: Date(timeIntervalSince1970: 1))
        try store.insert(ClipContent(kind: .text, text: "new"), source: nil, at: Date(timeIntervalSince1970: 2))

        _ = try paster.paste(old, into: nil)

        #expect(try store.items().map(\.preview) == ["old", "new"])
    }

    @Test func sendsCommandVToTargetApp() throws {
        let id = try store.insert(ClipContent(kind: .text, text: "x"), source: nil)
        let target = TargetApp(bundleID: "com.apple.Notes", name: "Notes")

        #expect(try paster.paste(id, into: target) == .pasted)
        #expect(keystroke.sentTo == [target])
    }

    @Test func copyToPasteboardWritesAndMovesToTopWithoutSendingCommandV() throws {
        let old = try store.insert(ClipContent(kind: .text, text: "old"), source: nil, at: Date(timeIntervalSince1970: 1))
        try store.insert(ClipContent(kind: .text, text: "new"), source: nil, at: Date(timeIntervalSince1970: 2))

        try paster.copyToPasteboard(old)

        #expect(pasteboard.written == [ClipContent(kind: .text, text: "old")])
        #expect(try store.items().map(\.preview) == ["old", "new"])
        #expect(keystroke.sentTo.isEmpty)
    }

    @Test func copyingFromThePanelLeavesTheOrderAlone() throws {
        // 面板里按 ⌘C（#35）：面板还开着，卡片先不动。
        let old = try store.insert(ClipContent(kind: .text, text: "old"), source: nil, at: Date(timeIntervalSince1970: 1))
        try store.insert(ClipContent(kind: .text, text: "new"), source: nil, at: Date(timeIntervalSince1970: 2))

        try paster.copyToPasteboard(old, touching: false)

        #expect(pasteboard.written == [ClipContent(kind: .text, text: "old")])
        #expect(try store.items().map(\.preview) == ["new", "old"])
        #expect(keystroke.sentTo.isEmpty)
    }

    @Test func withoutAccessibilityPermissionOnlyCopies() throws {
        keystroke.isTrusted = false
        let id = try store.insert(ClipContent(kind: .text, text: "x"), source: nil)

        #expect(try paster.paste(id, into: TargetApp(bundleID: "com.apple.Notes", name: "Notes")) == .copiedOnly)
        #expect(keystroke.sentTo.isEmpty)
        #expect(pasteboard.written == [ClipContent(kind: .text, text: "x")])
    }

    @Test func missingClipThrowsAndTouchesNothing() throws {
        #expect(throws: PasteError.clipNotFound(id: 42)) {
            try paster.paste(42, into: nil)
        }
        #expect(pasteboard.written.isEmpty)
        #expect(keystroke.sentTo.isEmpty)
    }
}

@MainActor
final class FakePasteboard: PasteboardWriting {
    private(set) var written: [ClipContent] = []
    /// 每次写入时附带的文件，和 `written` 一一对应。
    private(set) var files: [URL?] = []

    func write(_ content: ClipContent, attachingFile file: URL?) {
        written.append(content)
        files.append(file)
    }
}

@MainActor
final class FakeKeystroke: PasteKeystrokeSending {
    var isTrusted = true
    private(set) var sentTo: [TargetApp?] = []

    func sendPaste(to target: TargetApp?) {
        sentTo.append(target)
    }
}
