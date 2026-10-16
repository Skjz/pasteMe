import Foundation
import Testing
@testable import PasteMeCore

/// Paste Stack 的顺序和开关（#6）。监听 ⌘V 的部分在应用层，见 `PasteStackKeysTests`。
@MainActor
@Suite struct PasteStackTests {
    let stack = PasteStack()

    @Test func pastesInCopyOrderAndEndsAfterTheLastEntry() {
        stack.start()
        stack.push(1)
        stack.push(2)
        stack.push(3)

        #expect(stack.takeNext() == 1)
        #expect(stack.takeNext() == 2)
        #expect(stack.isActive)
        #expect(stack.takeNext() == 3)
        #expect(!stack.isActive)
        #expect(stack.takeNext() == nil)
    }

    @Test func copiesBeforeStartingOrAfterStoppingAreNotAdded() {
        stack.push(1)
        stack.start()
        stack.push(2)
        stack.stop()
        stack.push(3)

        #expect(stack.entries.isEmpty)
        stack.start()
        #expect(stack.entries.isEmpty)
    }

    @Test func emptyActiveStackTakesNothingAndStaysOn() {
        stack.start()

        #expect(stack.takeNext() == nil)
        #expect(stack.isActive)
    }

    @Test func removingEntriesKeepsTheStackOn() {
        stack.start()
        stack.push(1)
        stack.push(2)

        stack.remove(at: 0)
        stack.remove(at: 5)
        #expect(stack.entries == [2])
        stack.remove(at: 0)
        #expect(stack.isActive)
    }

    @Test func sameEntryCopiedTwiceIsPastedTwice() {
        stack.start()
        stack.push(7)
        stack.push(8)
        stack.push(7)

        #expect(stack.entries == [7, 8, 7])
    }

    @Test func everyChangeIsReported() {
        var changes = 0
        stack.onChange = { changes += 1 }

        stack.start()
        stack.push(1)
        _ = stack.takeNext()
        // 已经结束，再退出不算变化。
        stack.stop()

        #expect(changes == 3)
    }

    @Test func recorderAddsCopiesWhileStackIsOn() throws {
        let store = try ClipStore(path: ":memory:")
        let recorder = Recorder(store: store, pasteStack: stack)
        stack.start()

        let a = try #require(try recorder.record(ClipContent(kind: .text, text: "A"), from: nil))
        let b = try #require(try recorder.record(ClipContent(kind: .text, text: "B"), from: nil))
        // 再次复制 A：历史里还是一条，但栈里要再粘贴一次。
        try recorder.record(ClipContent(kind: .text, text: "A"), from: nil)

        #expect(stack.entries == [a, b, a])
        #expect(try store.count() == 2)
    }

    @Test func pausedRecorderAddsNothing() throws {
        let store = try ClipStore(path: ":memory:")
        let recorder = Recorder(store: store, pasteStack: stack)
        stack.start()
        recorder.pause()

        try recorder.record(ClipContent(kind: .text, text: "secret"), from: nil)

        #expect(stack.entries.isEmpty)
    }

    @Test func queryByIDsReturnsOnlyThoseEntries() throws {
        let store = try ClipStore(path: ":memory:")
        let a = try store.insert(ClipContent(kind: .text, text: "a"), source: nil, at: Date(timeIntervalSince1970: 1))
        try store.insert(ClipContent(kind: .text, text: "b"), source: nil, at: Date(timeIntervalSince1970: 2))
        let c = try store.insert(ClipContent(kind: .text, text: "c"), source: nil, at: Date(timeIntervalSince1970: 3))

        #expect(try store.items(matching: ClipQuery(ids: [a, c])).map(\.id) == [c, a])
        #expect(try store.items(matching: ClipQuery(ids: [])).isEmpty)
    }
}
