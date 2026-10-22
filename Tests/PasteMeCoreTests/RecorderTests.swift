import Foundation
import Testing
@testable import PasteMeCore

@MainActor
@Suite final class RecorderTests {
    let store: ClipStore
    var now = Date(timeIntervalSince1970: 1_000)
    let sound = FakeSound()
    var playsSound = false
    var recorder: Recorder!

    init() throws {
        store = try ClipStore(path: ":memory:")
        recorder = Recorder(
            store: store,
            sound: sound,
            playsSound: { [unowned self] in self.playsSound },
            now: { [unowned self] in self.now }
        )
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

    @Test func playsASoundForEveryRecordWhenTurnedOn() throws {
        playsSound = true

        try recorder.record(ClipContent(kind: .text, text: "a"), from: nil)
        #expect(sound.plays == 1)
        // 再次复制已有的内容只是把它移到最前，也算一次记录。
        try recorder.record(ClipContent(kind: .text, text: "a"), from: nil)
        try recorder.record(ClipContent(kind: .text, text: "b"), from: nil)
        #expect(sound.plays == 3)
    }

    @Test func staysSilentWhenTurnedOffOrPaused() throws {
        try recorder.record(ClipContent(kind: .text, text: "off"), from: nil)
        #expect(sound.plays == 0)

        playsSound = true
        recorder.pause()
        try recorder.record(ClipContent(kind: .text, text: "paused"), from: nil)
        #expect(sound.plays == 0)

        recorder.resume()
        try recorder.record(ClipContent(kind: .text, text: "resumed"), from: nil)
        #expect(sound.plays == 1)
    }
}

/// 记下播放了几次，不出声。
@MainActor
final class FakeSound: RecordSoundPlaying {
    var plays = 0

    func play() {
        plays += 1
    }
}
