import AVFoundation
import Foundation
import Testing
@testable import PasteMeCore

@Suite struct RecordChimeTests {
    let takes = RecordChime.samples()

    @Test func rotatesFourSlightlyDifferentTakes() {
        #expect(takes.count == 4)
        // 每个版本都不一样，轮流播放才自然。
        #expect(Set(takes.map { $0.map { $0.bitPattern } }).count == 4)
    }

    @Test func everyTakeIsShortAndStartsAndEndsWithoutAClick() {
        for take in takes {
            #expect(take.count <= Int(0.25 * RecordChime.sampleRate))
            #expect(abs(take[0]) < 0.001)
            // 最后 1 ms 已经淡出到听不见。
            #expect(take.suffix(48).allSatisfy { abs($0) < 0.001 })
            #expect(take.map(abs).max()! <= 0.5)
        }
    }

    @Test func everyTakeIsAsLoudAsChosen() {
        // 试听时选定的响度：最响的 20 ms 的 A 计权 RMS 是 -33.5 dBFS。4 个版本一样响，轮流播放时听不出谁大谁小。
        for take in takes {
            #expect(abs(RecordChime.loudestRMS(RecordChime.aWeighted(take)) - -33.5) < 0.01)
        }
    }

    @Test(arguments: [(200.0, -10.9), (500, -3.2), (1000, 0), (2000, 1.2)])
    func aWeightingMatchesTheStandard(frequency: Double, decibels: Double) {
        let sine = (0..<48_000).map { sin(2 * .pi * frequency * Double($0) / RecordChime.sampleRate) }
        // 跳过滤波器起步的一段，再和原来的正弦比。
        let weighted = RecordChime.aWeighted(sine).suffix(24_000)
        let rms = sqrt(weighted.map { $0 * $0 }.reduce(0, +) / Double(weighted.count))
        #expect(abs(20 * log10(rms / sqrt(0.5)) - decibels) < 0.2)
    }

    @Test func rotationNeverRepeatsATakeInARow() {
        var rotation = TakeRotation()
        var generator = SplitMix64(seed: 1)
        let picks = (0..<400).map { _ in rotation.next(count: 4, using: &generator) }
        #expect(zip(picks, picks.dropFirst()).allSatisfy { $0 != $1 })
        #expect(Set(picks) == [0, 1, 2, 3])

        var single = TakeRotation()
        #expect((0..<3).map { _ in single.next(count: 1, using: &generator) } == [0, 0, 0])
    }

    @Test func wavHeaderDescribesMonoPCM() {
        let samples = takes[0]
        let data = RecordChime.wav(samples)
        func string(_ offset: Int) -> String { String(decoding: data[offset..<offset + 4], as: UTF8.self) }
        func uint32(_ offset: Int) -> UInt32 { data[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        func uint16(_ offset: Int) -> UInt16 { UInt16(data[offset]) | UInt16(data[offset + 1]) << 8 }

        #expect(string(0) == "RIFF" && string(8) == "WAVE" && string(12) == "fmt " && string(36) == "data")
        #expect(uint32(4) == UInt32(data.count - 8))
        #expect(uint16(20) == 1) // PCM
        #expect(uint16(22) == 1) // 单声道
        #expect(uint32(24) == 48_000)
        #expect(uint16(34) == 16)
        #expect(uint32(40) == UInt32(samples.count * 2))
        #expect(data.count == 44 + samples.count * 2)
    }

    @Test func systemAudioReadsEveryTake() throws {
        for (data, samples) in zip(RecordChime.takes(), takes) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("RecordChimeTests-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            try data.write(to: url)

            let file = try AVAudioFile(forReading: url)
            #expect(file.fileFormat.sampleRate == 48_000)
            #expect(file.fileFormat.channelCount == 1)
            #expect(file.length == AVAudioFramePosition(samples.count))
        }
    }
}
