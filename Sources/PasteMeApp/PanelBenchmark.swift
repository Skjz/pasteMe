#if DEBUG
import AppKit
import Metal
import PasteMeCore
import QuartzCore

/// 调试用：面板呼出和收起动画的性能基准。用法和读数见 `docs/agents/ui-performance.md`。
///
/// `PASTEME_BENCH=<次数>` 启动时运行：历史为空时先填入测试条目，然后反复呼出、收起面板，
/// 每次记录两组数据后打印，最后打印中位数并退出。
/// - 主线程：display link 回调之间的间隔，以及 `show()` / `hide()` 本身的耗时。
/// - 实际上屏：面板里一个 2×2 的 Metal 图层每帧提交一次，`presentedTime` 之间的空档就是用户看到的掉帧。
@MainActor
enum PanelBenchmark {
    static var requestedCycles: Int? {
        ProcessInfo.processInfo.environment["PASTEME_BENCH"].flatMap(Int.init)
    }

    /// 120 Hz 下一帧的时长。比它长 1.5 倍以上的间隔按缺了几帧计数。
    nonisolated private static let framePeriod = 1.0 / 120
    /// 每次呼出或收起后统计多久。呼出约 0.4 秒静止，收起约 0.25 秒。
    private static let window = 0.45

    private static var recording = false
    private static var ticks: [CFTimeInterval] = []
    private static var probe: PresentProbe?

    /// `PanelAnimator` 每一帧调用。
    static func frameTick(in panel: NSWindow) {
        guard recording else { return }
        ticks.append(CACurrentMediaTime())
        if probe == nil { probe = PresentProbe(window: panel) }
        probe?.tick()
    }

    static func run(panel: PanelController, store: ClipStore, cycles: Int) {
        seedIfEmpty(store)
        var results: [String: [Sample]] = [:]

        func measure(_ phase: String, _ action: () -> Void, then next: @escaping @MainActor () -> Void) {
            ticks = []
            probe?.reset()
            recording = true
            let start = CACurrentMediaTime()
            action()
            let call = CACurrentMediaTime() - start
            ticks.insert(start, at: 0)
            after(window) {
                recording = false
                let sample = Sample(call: call, ticks: ticks, presented: probe?.presented ?? [])
                print("\(phase) \(sample.line)")
                results[phase, default: []].append(sample)
                next()
            }
        }

        func cycle(_ index: Int) {
            guard index < cycles else {
                // 第一次是冷启动，不计入中位数。
                for phase in ["show", "hide"] {
                    let samples = Array((results[phase] ?? []).dropFirst())
                    print("median \(phase) \(Sample.medianLine(samples))")
                }
                fflush(stdout)
                NSApp.terminate(nil)
                return
            }
            measure("show", { panel.show() }) {
                after(0.3) {
                    measure("hide", { panel.hide() }) {
                        after(0.3) { cycle(index + 1) }
                    }
                }
            }
        }

        // 等启动时的其他工作做完再开始。
        after(1.0) { cycle(0) }
    }

    private static func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated { body() }
        }
    }

    /// 一次呼出或收起的数据。
    private struct Sample {
        var callMS: Double
        var mainMissed: Int
        var mainLongestMS: Double
        var presented: Int
        var presentMissed: Int
        var presentLongestMS: Double

        init(call: Double, ticks: [CFTimeInterval], presented: [CFTimeInterval]) {
            callMS = call * 1000
            (mainMissed, mainLongestMS) = Self.gaps(ticks)
            self.presented = presented.count
            (presentMissed, presentLongestMS) = Self.gaps(presented.sorted())
        }

        /// 相邻时间点之间缺了几帧（累计），以及最长的间隔。
        static func gaps(_ times: [CFTimeInterval]) -> (Int, Double) {
            let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
            let missed = gaps.map { max(0, Int(($0 / framePeriod).rounded()) - 1) }.reduce(0, +)
            return (missed, (gaps.max() ?? 0) * 1000)
        }

        var line: String {
            String(
                format: "present_missed=%d presented=%d present_longest_ms=%.1f main_missed=%d main_longest_ms=%.1f call_ms=%.1f",
                presentMissed, presented, presentLongestMS, mainMissed, mainLongestMS, callMS
            )
        }

        static func medianLine(_ samples: [Sample]) -> String {
            func median<T: Comparable>(_ values: [T]) -> T? {
                values.isEmpty ? nil : values.sorted()[values.count / 2]
            }
            guard let presentMissed = median(samples.map(\.presentMissed)),
                  let mainMissed = median(samples.map(\.mainMissed)),
                  let call = median(samples.map(\.callMS))
            else { return "no samples" }
            return String(format: "present_missed=%d main_missed=%d call_ms=%.1f (n=%d)", presentMissed, mainMissed, call, samples.count)
        }
    }

    /// 历史为空时填入约 30 条测试条目：来自本机已安装的几个系统应用，有文本、链接和图片，
    /// 卡片的标题栏颜色、图标和缩略图都和真实使用时一样需要绘制。
    private static func seedIfEmpty(_ store: ClipStore) {
        guard (try? store.count()) == 0 else { return }
        let apps = [
            ("com.apple.Safari", "Safari"), ("com.apple.Notes", "备忘录"), ("com.apple.finder", "访达"),
            ("com.apple.Music", "音乐"), ("com.apple.TextEdit", "文本编辑"), ("com.apple.Terminal", "终端"),
            ("com.apple.mail", "邮件"), ("com.apple.iCal", "日历"), ("com.apple.Maps", "地图"),
            ("com.apple.Photos", "照片"),
        ].filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.0) != nil }
        guard !apps.isEmpty else { return }
        let start = Date().addingTimeInterval(-3600)
        for index in 0..<30 {
            let app = apps[index % apps.count]
            let content: ClipContent
            if index % 7 == 3, let image = gradientPNG(hue: Double(index) / 30) {
                content = ClipContent(kind: .image, image: image)
            } else if index % 5 == 1 {
                content = ClipContent(kind: .link, text: "https://example.com/pasteme/bench/\(index)")
            } else {
                content = ClipContent(kind: .text, text: "测试条目 \(index)：来自\(app.1)的一段文字，用来填满卡片。")
            }
            _ = try? store.insert(content, source: ClipSource(bundleID: app.0, name: app.1), at: start.addingTimeInterval(Double(index) * 60))
        }
    }

    private static func gradientPNG(hue: Double) -> Data? {
        let size = NSSize(width: 800, height: 500)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(
                starting: NSColor(hue: hue, saturation: 0.7, brightness: 0.9, alpha: 1),
                ending: NSColor(hue: (hue + 0.3).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.5, alpha: 1)
            )?.draw(in: rect, angle: 30)
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// 面板内容图层里一个几乎透明的 2×2 Metal 图层。每帧提交一次画面，记录系统报告的实际上屏时间。
@MainActor
private final class PresentProbe {
    private let layer = CAMetalLayer()
    private let queue: MTLCommandQueue
    private var flip = false
    private(set) var presented: [CFTimeInterval] = []

    init?(window: NSWindow) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let host = window.contentView?.layer
        else { return nil }
        self.queue = queue
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        layer.drawableSize = CGSize(width: 2, height: 2)
        layer.opacity = 0.01
        host.addSublayer(layer)
    }

    func reset() {
        presented = []
    }

    func tick() {
        guard let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        // 每帧换一种颜色，确保每一帧的内容都不同，系统不会跳过它。
        flip.toggle()
        pass.colorAttachments[0].clearColor = MTLClearColor(red: flip ? 1 : 0, green: 0, blue: 0, alpha: 1)
        buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        drawable.addPresentedHandler { [weak self] drawable in
            let time = drawable.presentedTime
            // presentedTime 为 0 表示这一帧没有上屏，例如面板已经离开屏幕。
            guard time > 0 else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.presented.append(time) }
            }
        }
        buffer.present(drawable)
        buffer.commit()
    }
}
#endif
