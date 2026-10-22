import Foundation

/// 复制被记录时的提示音（#25）：一张纸滑进剪贴板的夹子，夹子「嗒」地夹住。
///
/// 声音在代码里合成，不带音频文件：SwiftPM 的资源包放不进签名的 .app，`swift run` 时也找不到。
/// 它是和用户一起试听了十几轮选定的：明亮的乐音太尖，整段撕纸声太吵，单独的乐音精致但不耐听，只有敲击又太闷、
/// 不像剪贴板。最后定下的是干净的夹子声垫着纸的质感，一听就是剪贴板；不加乐音。4 个版本轮流播放
/// （`TakeRotation`），纸的颗粒、滑动长短和夹子的音高略有不同，像真的纸每次都不一样，听不腻。改参数前先试听。
public enum RecordChime {
    static let sampleRate = 48_000.0
    /// 每个版本最响的 20 ms 的 A 计权 RMS，单位 dBFS。系统自带的提示音按同样的方法量在 -28（Bottle）到 -16（Tink）之间，
    /// 这个比它们都轻。
    static let loudness = -33.5

    /// 4 个版本，每个是一个 16 位单声道 PCM 的 WAV 文件。
    public static func takes() -> [Data] {
        samples().map(wav)
    }

    /// 4 个版本的样本，-1...1，每次生成的都一样。
    static func samples() -> [[Double]] {
        // （纸滑动的秒数, 夹板音高的倍数, 随机种子）
        let variations: [(Double, Double, UInt64)] = [(0.066, 1.0, 11), (0.062, 0.985, 29), (0.07, 1.015, 47), (0.064, 1.005, 61)]
        return variations.map { slide, pitch, seed in
            let take = take(slide: slide, board: 220 * pitch, seed: seed)
            let gain = pow(10, (loudness - loudestRMS(aWeighted(take))) / 20)
            return take.map { $0 * gain }
        }
    }

    /// 一个版本：纸滑 `slide` 秒；夹子落下（另一边晚 4 ms 落下，20 ms 后轻轻回弹），落下前 6 ms 有极轻的卡扣声；
    /// 纸被压住「嚓」一下，再安顿。纸声的大小按夹子的峰值算。最后去掉 6.5 kHz 以上的毛刺，加几次早期反射。
    private static func take(slide: Double, board: Double, seed: UInt64) -> [Double] {
        let count = Int((slide + 0.17) * sampleRate)
        var clip = hit(count: count, at: slide, board: board, tau: 0.026, octave: 0.2, ringLevel: 0.05, clickLevel: 0.14, seed: seed)
        let clipPeak = clip.map(abs).max()!
        let latch = click(seed: seed + 100, count: count, center: 2400, tau: 0.0004, at: slide - 0.006)
        clip = add(clip, latch.map { $0 * clipPeak }, gain: 0.06)
        let otherSide = hit(count: count, at: slide + 0.004, board: board * 1.03, tau: 0.026 * 0.8, octave: 0.2,
                            ringLevel: 0.05, clickLevel: 0.14, seed: seed + 1)
        clip = add(clip, otherSide, gain: 0.55)
        let rebound = hit(count: count, at: slide + 0.02, board: board * 1.05, tau: 0.026 * 0.5, squash: 1, octave: 0,
                          ringLevel: 0, clickLevel: 0.14 * 0.5, seed: seed + 2)
        clip = add(clip, rebound, gain: pow(10, -20.0 / 20))

        let peak = clip.map(abs).max()!
        var out = add(clip, paperSlide(seed: seed + 7, count: count, length: slide).map { $0 * peak }, gain: 0.3)
        out = add(out, paperCrush(seed: seed + 8, count: count, at: slide).map { $0 * peak }, gain: 0.25)
        out = add(out, paperSettle(seed: seed + 9, count: count, at: slide + 0.015).map { $0 * peak }, gain: 0.09)
        return fadeOut(withReflections(lowpass(out, 6500)))
    }

    // MARK: - 夹子

    /// 夹子落在夹板上的一次撞击：夹板的闷响（三个不成整数倍的振动模式，音高从 `squash` 倍压下来；
    /// `octave` 是 2 倍频的大小，笔记本扬声器放不出 220 Hz 时靠它听到）、很轻的钢片振动和撞击的「咔」。
    private static func hit(count: Int, at time: Double, board f: Double, tau: Double, squash: Double = 1.12, octave: Double,
                            ringLevel: Double, clickLevel: Double, seed: UInt64) -> [Double] {
        var modes = [
            Mode(frequency: f, amp: 1, tau: tau, glideFrom: squash, glide: 0.005),
            Mode(frequency: f * 1.59, amp: 0.4, tau: tau * 0.55),
            Mode(frequency: f * 2.14, amp: 0.2, tau: tau * 0.35),
        ]
        if octave > 0 {
            modes.append(Mode(frequency: f * 2, amp: octave, tau: tau * 0.6, glideFrom: squash, glide: 0.005))
        }
        let duration = Double(count) / sampleRate + 0.01
        let body = Array(strike(modes, duration: duration, attackTime: 0.0008, delay: time).prefix(count))
        let peak = body.map(abs).max()!
        // 弹簧钢片：薄板自由振动的模式比例 1、2.76、5.40，定在夹板的 6 倍，和闷响和谐；8 ms 收住。
        let ring = peakNormalized(Array(strike([
            Mode(frequency: f * 6, amp: 1, tau: 0.008),
            Mode(frequency: f * 6 * 2.76, amp: 0.35, tau: 0.008 * 0.5),
            Mode(frequency: f * 6 * 5.4, amp: 0.08, tau: 0.008 * 0.25),
        ], duration: duration, attackTime: 0.0005, delay: time).prefix(count)))
        let snap = click(seed: seed, count: count, center: 1800, tau: 0.0006, at: time)
        return add(add(body, ring.map { $0 * peak }, gain: ringLevel), snap.map { $0 * peak }, gain: clickLevel)
    }

    /// 撞击的「咔」：带通过的噪声，从 `time` 秒开始按 `tau` 指数衰减，峰值归一到 1。
    private static func click(seed: UInt64, count: Int, center: Double, tau: Double, at time: Double) -> [Double] {
        let start = Int(time * sampleRate)
        var generator = SplitMix64(seed: seed)
        var filter = Bandpass(center: center, q: 0.8)
        let burst = peakNormalized((0..<count - start).map { i in
            let t = Double(i) / sampleRate
            return filter.process(Double.random(in: -1...1, using: &generator) * exp(-t / tau))
        })
        return [Double](repeating: 0, count: start) + burst
    }

    // MARK: - 纸

    /// 纸滑动：中频的「沙」（带通中心从 1.2 kHz 升到 2.8 kHz，像越滑越快）加 3.2 kHz 附近很轻的「空气」，
    /// 乘上纸面卡住又滑开的颗粒；升余弦渐强 `length` 秒，被夹住时 5 ms 停住。峰值归一到 1。
    private static func paperSlide(seed: UInt64, count: Int, length: Double) -> [Double] {
        var generator = SplitMix64(seed: seed)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        var air = Bandpass(center: 3200, q: 0.5)
        let slip = stickSlip(seed: seed + 50, count: count, grains: 500, depth: 0.35)
        return peakNormalized((0..<count).map { i -> Double in
            let t = Double(i) / sampleRate
            let envelope: Double = t < length ? 0.5 - 0.5 * cos(.pi * t / length)
                : t < length + 0.005 ? 1 - (t - length) / 0.005 : 0
            let x = Double.random(in: -1...1, using: &generator)
            let center = 1200 * pow(2800.0 / 1200, min(t / length, 1))
            let w = 2 * .pi * center / sampleRate, alpha = sin(w) / (2 * 0.6), a0 = 1 + alpha
            let y = (alpha / a0) * x - (alpha / a0) * x2 - (-2 * cos(w) / a0) * y1 - ((1 - alpha) / a0) * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            let breath = air.process(Double.random(in: -1...1, using: &generator))
            return (y + 0.4 * breath) * envelope * slip[i]
        })
    }

    /// 夹子压住纸的一下「嚓」：2.5 kHz 带通噪声，0.5 ms 起音、10 ms 衰减，带细碎的颗粒。峰值归一到 1。
    private static func paperCrush(seed: UInt64, count: Int, at time: Double) -> [Double] {
        var generator = SplitMix64(seed: seed)
        var band = Bandpass(center: 2500, q: 0.6)
        let slip = stickSlip(seed: seed + 60, count: count, grains: 1500, depth: 0.5)
        return peakNormalized((0..<count).map { i -> Double in
            let t = Double(i) / sampleRate - time
            let envelope = t < 0 ? 0 : (t < 0.0005 ? t / 0.0005 : exp(-(t - 0.0005) / 0.01))
            return band.process(Double.random(in: -1...1, using: &generator) * envelope * slip[i])
        })
    }

    /// 纸张安顿：夹住后一下很轻的纸声（1.6 kHz 带通，14 ms 衰减）。峰值归一到 1。
    private static func paperSettle(seed: UInt64, count: Int, at time: Double) -> [Double] {
        var generator = SplitMix64(seed: seed)
        var band = Bandpass(center: 1600, q: 0.7)
        return peakNormalized((0..<count).map { i -> Double in
            let t = Double(i) / sampleRate - time
            let envelope = t < 0 ? 0 : (t < 0.003 ? t / 0.003 : exp(-(t - 0.003) / 0.014))
            return band.process(Double.random(in: -1...1, using: &generator) * envelope)
        })
    }

    /// 纸面一下下卡住又滑开：每秒 `grains` 个随机的小起伏，每个 1.5 ms 衰减。返回围绕 1 上下的包络。
    private static func stickSlip(seed: UInt64, count: Int, grains: Double, depth: Double) -> [Double] {
        var generator = SplitMix64(seed: seed)
        var level = 0.0
        let decay = exp(-1 / (0.0015 * sampleRate))
        return (0..<count).map { _ in
            level *= decay
            if Double.random(in: 0..<1, using: &generator) < grains / sampleRate {
                level += Double.random(in: 0.4...1, using: &generator)
            }
            return 1 - depth + depth * 2 * min(level, 1.5)
        }
    }

    // MARK: - 合成的零件

    /// 一个衰减的正弦分量，开头可以从 `glideFrom` 倍的音高在 `glide` 秒内滑到 1 倍。
    private struct Mode {
        var frequency: Double
        var amp: Double
        var tau: Double
        var glideFrom = 1.0
        var glide = 0.012
    }

    /// 几个分量相加，从 `delay` 秒开始；相位按瞬时频率累加，滑音时不会跳。起音是 `attackTime` 秒的升余弦，没有咔哒声。
    private static func strike(_ modes: [Mode], duration: Double, attackTime: Double, delay: Double) -> [Double] {
        var phases = [Double](repeating: 0, count: modes.count)
        return (0..<Int(duration * sampleRate)).map { i in
            let t = Double(i) / sampleRate - delay
            guard t > 0 else { return 0 }
            var v = 0.0
            for (k, m) in modes.enumerated() {
                let ratio = t < m.glide ? m.glideFrom + (1 - m.glideFrom) * (t / m.glide) : 1
                phases[k] += 2 * .pi * m.frequency * ratio / sampleRate
                v += m.amp * sin(phases[k]) * exp(-t / m.tau)
            }
            return v * (t < attackTime ? 0.5 - 0.5 * cos(.pi * t / attackTime) : 1)
        }
    }

    /// RBJ 带通。
    private struct Bandpass {
        private let b0: Double, b2: Double, a1: Double, a2: Double
        private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        init(center: Double, q: Double) {
            let w = 2 * .pi * center / sampleRate, alpha = sin(w) / (2 * q), a0 = 1 + alpha
            b0 = alpha / a0; b2 = -alpha / a0; a1 = -2 * cos(w) / a0; a2 = (1 - alpha) / a0
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }

    /// 一阶低通。
    private static func lowpass(_ s: [Double], _ cutoff: Double) -> [Double] {
        let a = exp(-2 * .pi * cutoff / sampleRate)
        var y = 0.0
        return s.map { y = (1 - a) * $0 + a * y; return y }
    }

    /// 几次早期反射（4.3、9.1、15.7 ms），像放在桌上的东西，不留尾音。反射先过 3 kHz 一阶低通。
    private static func withReflections(_ s: [Double]) -> [Double] {
        let dull = lowpass(s, 3000)
        var out = s
        for (delay, db) in [(0.0043, -13.0), (0.0091, -18.0), (0.0157, -23.0)] {
            let d = Int(delay * sampleRate), g = pow(10, db / 20)
            for i in d..<out.count { out[i] += g * dull[i - d] }
        }
        return out
    }

    private static func add(_ a: [Double], _ b: [Double], gain: Double) -> [Double] {
        (0..<max(a.count, b.count)).map { i in (i < a.count ? a[i] : 0) + gain * (i < b.count ? b[i] : 0) }
    }

    private static func peakNormalized(_ s: [Double]) -> [Double] {
        let peak = s.map(abs).max() ?? 1
        return s.map { $0 / peak }
    }

    /// 结尾 20 ms 线性淡出到 0，截断处不会有爆音。
    private static func fadeOut(_ s: [Double]) -> [Double] {
        var out = s
        let fade = Int(0.02 * sampleRate)
        for i in 0..<fade { out[out.count - fade + i] *= Double(fade - i) / Double(fade) }
        return out
    }

    // MARK: - 响度和文件

    /// A 计权（48 kHz，IEC 61672）：按人耳对不同频率的灵敏度加权，响度按它算才和听到的一致。
    static func aWeighted(_ s: [Double]) -> [Double] {
        let b = [0.234301792299513, -0.468603584599026, -0.234301792299513, 0.937207168598052, -0.234301792299513, -0.468603584599026, 0.234301792299513]
        let a = [1.0, -4.113043408775871, 6.553121752655047, -4.990849294163381, 1.785737302937573, -0.246190595319487, 0.011224250033231]
        var x = [Double](repeating: 0, count: 7), y = [Double](repeating: 0, count: 7)
        return s.map { v in
            x.insert(v, at: 0); x.removeLast()
            var out = 0.0
            for k in 0..<7 { out += b[k] * x[k] }
            for k in 1..<7 { out -= a[k] * y[k - 1] }
            y.insert(out, at: 0); y.removeLast()
            return out
        }
    }

    /// 最响的 20 ms 的 RMS，单位 dBFS。
    static func loudestRMS(_ s: [Double]) -> Double {
        let window = Int(0.02 * sampleRate)
        var loudest = 0.0
        for start in stride(from: 0, to: s.count - window, by: window / 2) {
            loudest = max(loudest, sqrt(s[start..<start + window].map { $0 * $0 }.reduce(0, +) / Double(window)))
        }
        return 20 * log10(loudest)
    }

    static func wav(_ samples: [Double]) -> Data {
        var data = Data()
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let dataSize = UInt32(samples.count * 2)
        append("RIFF"); append(36 + dataSize); append("WAVE")
        append("fmt "); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate) * 2); append(UInt16(2)); append(UInt16(16))
        append("data"); append(dataSize)
        for sample in samples {
            append(Int16((max(-1, min(1, sample)) * Double(Int16.max)).rounded()))
        }
        return data
    }
}

/// 从几个版本里随机挑一个播放，不和上一次相同。
public struct TakeRotation {
    private var last: Int?

    public init() {}

    public mutating func next(count: Int) -> Int {
        var generator = SystemRandomNumberGenerator()
        return next(count: count, using: &generator)
    }

    mutating func next(count: Int, using generator: inout some RandomNumberGenerator) -> Int {
        var index = Int.random(in: 0..<count, using: &generator)
        if count > 1, index == last {
            index = (index + 1) % count
        }
        last = index
        return index
    }
}

/// 固定种子的随机数，合成里的噪声每次都一样。
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
