import Foundation
import Testing
@testable import PasteMeCore

@MainActor
@Suite final class RecorderTests {
    let store: ClipStore
    var now = Date(timeIntervalSince1970: 1_000)
    var recorder: Recorder!

    init() throws {
        store = try ClipStore(path: ":memory:")
        recorder = Recorder(store: store) { [unowned self] in self.now }
    }

    @Test func recordsCopiesAndReportsTheirIDs() throws {
        var recorded: [Int64] = []
        recorder.onRecord = { recorded.append($0) }

        let id = try recorder.record(ClipContent(kind: .text, text: "a"), from: ClipSource(bundleID: "com.apple.Notes", name: "Notes"))

        #expect(id != nil)
        #expect(recorded == [id])
        #expect(try store.items().map(\.sourceName) == ["Notes"])
        #expect(try store.items().first?.createdAt == now)
    }

    @Test func pausingUntilResumedSkipsCopies() throws {
        recorder.pause()
        now += 24 * 3600

        #expect(recorder.isPaused)
        #expect(try recorder.record(ClipContent(kind: .text, text: "secret"), from: nil) == nil)
        #expect(try store.count() == 0)

        recorder.resume()
        #expect(!recorder.isPaused)
        #expect(try recorder.record(ClipContent(kind: .text, text: "after"), from: nil) != nil)
    }

    @Test func timedPauseEndsAtItsDeadline() throws {
        recorder.pause(until: now + 300)

        now += 299
        #expect(recorder.isPaused)
        #expect(try recorder.record(ClipContent(kind: .text, text: "during"), from: nil) == nil)

        now += 1
        #expect(!recorder.isPaused)
        #expect(try recorder.record(ClipContent(kind: .text, text: "after"), from: nil) != nil)
        #expect(try store.items().map(\.preview) == ["after"])
        // 到时后第一次记录时补上恢复，状态不再显示为暂停。
        #expect(recorder.pausedUntil == nil)
    }

    @Test func pauseChangesAreReported() {
        var changes = 0
        recorder.onPauseChange = { changes += 1 }

        recorder.pause(until: now + 60)
        recorder.pause()
        recorder.resume()
        // 没有暂停时恢复不算一次变化。
        recorder.resume()

        #expect(changes == 3)
    }
}
