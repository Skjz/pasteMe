#if DEBUG
import AppKit
import Metal
import PasteMeCore
import QuartzCore

/// 调试用：面板动画的性能基准。用法和读数见 `docs/agents/ui-performance.md`。
///
/// `PASTEME_BENCH=<次数>` 启动时运行：历史为空时先填入测试条目，然后反复呼出、收起面板，
/// 每次记录两组数据后打印，最后打印中位数并退出。
/// 再加上 `PASTEME_BENCH_DELETE=1` 时改为呼出面板后反复删除选中的卡片、再撤销，测颗粒动画和补位动画；
/// `PASTEME_BENCH_MOVE=1` 时改为呼出面板后像按住方向键一样连续向右、再向左移动光标，测选中项变化时的重画；
/// `PASTEME_BENCH_SEARCH=1` 时改为呼出面板后在搜索框里逐字打字、用输入法组字、再逐字删掉，测每次按键的耗时。
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
    /// 删除后统计多久：颗粒飘散约 1.4 秒，之后右边的卡片补位约 0.5 秒。
    private static let deleteWindow = 2.0
    /// 撤销后统计多久：右边的卡片让位、颗粒聚拢，约 1 秒。
    private static let undoWindow = 1.5

    private static var measuresDelete: Bool {
        ProcessInfo.processInfo.environment["PASTEME_BENCH_DELETE"] == "1"
    }

    private static var measuresMove: Bool {
        ProcessInfo.processInfo.environment["PASTEME_BENCH_MOVE"] == "1"
    }

    private static var measuresSearch: Bool {
        ProcessInfo.processInfo.environment["PASTEME_BENCH_SEARCH"] == "1"
    }

    /// 打字的间隔。连续打字时一个字大约 80 ms。按键按固定的节奏发出，不等上一次按键处理完：
    /// 慢的版本不会因此打得更慢。
    private static let keyInterval = 0.08

    /// 按住方向键时一次连发移动几格、间隔多久（系统最快的按键重复约 30 ms 一次）。
    private static let moveSteps = 8
    private static let moveInterval = 0.05
    /// 连发结束后再统计多久：光标和放大的卡片停稳约 0.35 秒。
    private static var moveWindow: Double { Double(moveSteps) * moveInterval + 0.35 }

    private static var recording = false
    /// 测删除时逐帧调用 `frameTick` 的 display link。颗粒动画自己的 display link 在撤销后要等一会儿才开始，
    /// 不能用来计时。
    private static var ticker: BenchTicker?
    private static var ticks: [CFTimeInterval] = []
    private static var probe: PresentProbe?

    /// `PanelAnimator` 每一帧调用。
    static func frameTick(in panel: NSWindow) {
        guard recording else { return }
        ticks.append(CACurrentMediaTime())
        if probe == nil { probe = PresentProbe(window: panel) }
        probe?.tick()
    }

    static func run(panel: PanelController, model: HistoryModel, store: ClipStore, cycles: Int) {
        seedIfEmpty(store)
        var results: [String: [Sample]] = [:]
        let phases = measuresDelete ? ["delete", "undo"] : measuresMove ? ["right", "left"]
            : measuresSearch ? SearchKey.phases : ["show", "hide"]

        func measure(
            _ phase: String, for duration: Double = window, _ action: () -> Void,
            then next: @escaping @MainActor () -> Void
        ) {
            ticks = []
            probe?.reset()
            recording = true
            ticker?.start()
            let start = CACurrentMediaTime()
            action()
            let call = CACurrentMediaTime() - start
            ticks.insert(start, at: 0)
            after(duration) {
                recording = false
                ticker?.stop()
                let sample = Sample(call: call, ticks: ticks, presented: probe?.presented ?? [])
                print("\(phase) \(sample.line)")
                results[SearchKey.phase(of: phase), default: []].append(sample)
                next()
            }
        }

        func cycle(_ index: Int) {
            guard index < cycles else {
                // 第一次是冷启动，不计入中位数。测搜索时去掉第一轮的所有按键。
                for phase in phases {
                    let firstRound = measuresSearch ? SearchKey.script.filter { $0.phase == phase }.count : 1
                    let samples = Array((results[phase] ?? []).dropFirst(firstRound))
                    print("median \(phase) \(Sample.medianLine(samples))")
                    if measuresSearch { print("worst \(phase) \(Sample.worstLine(samples))") }
                }
                fflush(stdout)
                NSApp.terminate(nil)
                return
            }
            if measuresDelete {
                measure("delete", for: deleteWindow, { model.delete() }) {
                    after(0.3) {
                        measure("undo", for: undoWindow, { model.undoDelete() }) {
                            after(0.3) { cycle(index + 1) }
                        }
                    }
                }
                return
            }
            if measuresSearch {
                typeRound(in: panel.window) { keys in
                    for (key, sample) in keys {
                        print("\(key.label) \(sample.line)")
                        results[key.phase, default: []].append(sample)
                    }
                    after(0.3) { cycle(index + 1) }
                }
                return
            }
            if measuresMove {
                measure("right", for: moveWindow, { moveBurst(model, by: 1) }) {
                    after(0.3) {
                        measure("left", for: moveWindow, { moveBurst(model, by: -1) }) {
                            after(0.3) { cycle(index + 1) }
                        }
                    }
                }
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

        // 等启动时的其他工作做完再开始。测删除和移动光标时先呼出面板，焦点放到卡片上，和按 ⌘⌫、← → 时一样。
        if measuresDelete || measuresMove {
            after(1.0) {
                panel.show()
                model.focus = .cards
                ticker = BenchTicker(window: panel.window)
                after(1.0) { cycle(0) }
            }
        } else if measuresSearch {
            if let count = try? store.count(), count < 1_000 {
                print("search: 历史只有 \(count) 条，看不出查询和换卡片的开销，用 PASTEME_BENCH_HISTORY 指向几千条的历史")
            }
            // 焦点放到搜索框上，按键交给它的字段编辑器，和真的打字一样经过 `TextField` 的绑定。
            after(1.0) {
                panel.show()
                model.focus = .search
                ticker = BenchTicker(window: panel.window)
                after(1.0) { cycle(0) }
            }
        } else {
            after(1.0) { cycle(0) }
        }
    }

    /// 按 `SearchKey.script` 打一轮字，每 `keyInterval` 发一次按键。整轮连续记录主线程的帧和上屏的帧，
    /// 打完再按按键的时间切开：每次按键的读数从它发出算到下一次按键发出，跨过两次按键的空档算在后一次上。
    private static func typeRound(in window: NSWindow, done: @escaping @MainActor ([(SearchKey, Sample)]) -> Void) {
        let keys = SearchKey.script
        var starts: [CFTimeInterval] = []
        var calls: [Double] = []
        ticks = []
        probe?.reset()
        recording = true
        ticker?.start()
        let origin = CACurrentMediaTime()

        func press(_ index: Int) {
            guard index < keys.count else {
                // 等最后一次按键的结果上屏，上屏的回调也送回来。
                after(keyInterval + 0.15) {
                    recording = false
                    ticker?.stop()
                    let end = CACurrentMediaTime()
                    let frames = (probe?.frames ?? []).sorted { $0.presented < $1.presented }
                    done(keys.indices.map { i in
                        let sample = Sample(
                            call: calls[i], start: starts[i], end: i + 1 < starts.count ? starts[i + 1] : end,
                            ticks: ticks, frames: frames
                        )
                        return (keys[i], sample)
                    })
                }
                return
            }
            let start = CACurrentMediaTime()
            guard keys[index].send(to: window) else {
                print("search: 搜索框不是第一响应者，按键没有送到，停止")
                fflush(stdout)
                exit(1)
            }
            calls.append(CACurrentMediaTime() - start)
            starts.append(start)
            let next = origin + Double(index + 1) * keyInterval
            after(max(0, next - CACurrentMediaTime())) { press(index + 1) }
        }
        press(0)
    }

    /// 第一格立刻移动（计入 `call_ms`），其余的按连发的间隔接着移动。
    private static func moveBurst(_ model: HistoryModel, by offset: Int) {
        model.moveSelection(by: offset)
        for step in 1..<moveSteps {
            after(Double(step) * moveInterval) { model.moveSelection(by: offset) }
        }
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
        /// 测搜索时：从按键发出到它的结果上屏。没有上屏的帧（例如远程桌面的虚拟显示器）时为 nil。
        var keyToPresentMS: Double?

        init(call: Double, ticks: [CFTimeInterval], presented: [CFTimeInterval]) {
            callMS = call * 1000
            (mainMissed, mainLongestMS) = Self.gaps(ticks)
            self.presented = presented.count
            (presentMissed, presentLongestMS) = Self.gaps(presented.sorted())
        }

        /// 一次按键在连续记录里的那一段：从 `start` 到 `end`（下一次按键发出）。前一段最后的那一帧也带上，
        /// 跨过两次按键的空档算在这一次上。
        ///
        /// 按键到上屏：按键的同步部分做完以后的第二帧 display link 时，这次按键的排版和图层提交一定已经做完
        /// （第一帧时可能还在提交），这一帧探针画面的上屏时间就是结果最晚的上屏时间，最多比实际晚一帧。
        init(call: Double, start: CFTimeInterval, end: CFTimeInterval, ticks: [CFTimeInterval], frames: [PresentProbe.Frame]) {
            let window = ticks.filter { $0 >= start && $0 < end }
            self.init(
                call: call,
                ticks: [start] + window,
                presented: (frames.last { $0.presented < start }.map { [$0.presented] } ?? [])
                    + frames.map(\.presented).filter { $0 >= start && $0 < end }
            )
            presented = frames.filter { $0.presented >= start && $0.presented < end }.count
            let second = ticks.filter { $0 > start + call }.dropFirst().first
            keyToPresentMS = second.flatMap { tick in
                frames.first { $0.submitted >= tick }.map { ($0.presented - start) * 1000 }
            }
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
            ) + (keyToPresentMS.map { String(format: " key_to_present_ms=%.1f", $0) } ?? "")
        }

        static func medianLine(_ samples: [Sample]) -> String {
            func median<T: Comparable>(_ values: [T]) -> T? {
                values.isEmpty ? nil : values.sorted()[values.count / 2]
            }
            guard let presentMissed = median(samples.map(\.presentMissed)),
                  let mainMissed = median(samples.map(\.mainMissed)),
                  let call = median(samples.map(\.callMS))
            else { return "no samples" }
            let keyToPresent = median(samples.compactMap(\.keyToPresentMS)).map { String(format: " key_to_present_ms=%.1f", $0) } ?? ""
            return String(format: "present_missed=%d main_missed=%d call_ms=%.1f", presentMissed, mainMissed, call)
                + keyToPresent + " (n=\(samples.count))"
        }

        /// 最差的那次：缺帧最多、主线程卡得最久、调用最慢的各是多少。
        static func worstLine(_ samples: [Sample]) -> String {
            guard !samples.isEmpty else { return "no samples" }
            return String(
                format: "present_missed=%d present_longest_ms=%.1f main_longest_ms=%.1f call_ms=%.1f",
                samples.map(\.presentMissed).max()!, samples.map(\.presentLongestMS).max()!,
                samples.map(\.mainLongestMS).max()!, samples.map(\.callMS).max()!
            ) + (samples.compactMap(\.keyToPresentMS).max().map { String(format: " key_to_present_ms=%.1f", $0) } ?? "")
        }
    }

    /// 历史为空时填入约 30 条测试条目：来自本机已安装的几个系统应用，有文本、链接和图片，
    /// 卡片的标题栏颜色、图标和缩略图都和真实使用时一样需要绘制。链接带着链接预览（网站图标用来源应用的图标，
    /// 一半有网页标题），呼出时依次出现的前几张卡片里有两张链接。
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
            } else if index % 5 == 1 || index == 28 {
                content = ClipContent(kind: .link, text: "https://example.com/pasteme/bench/\(index)")
            } else {
                content = ClipContent(kind: .text, text: "测试条目 \(index)：来自\(app.1)的一段文字，用来填满卡片。")
            }
            let id = try? store.insert(content, source: ClipSource(bundleID: app.0, name: app.1), at: start.addingTimeInterval(Double(index) * 60))
            if content.kind == .link, let id, let icon = iconPNG(bundleID: app.0) {
                let title = index % 2 == 0 ? "测试网页 \(index)：链接预览的标题" : ""
                try? store.setLinkPreview(LinkPreview(title: title, icon: icon), id: id)
            }
        }
    }

    private static func iconPNG(bundleID: String) -> Data? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        var rect = NSRect(x: 0, y: 0, width: 128, height: 128)
        guard let image = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
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

/// 测搜索时的一次按键：打一个字、输入法组字时改一次未确认的文字，或者删一个字。
/// 都交给搜索框的字段编辑器，和用键盘打字时一样经过 `TextField` 的绑定。
@MainActor
private struct SearchKey {
    enum Action {
        case insert(String)
        case mark(String)
        case deleteBackward
    }

    let action: Action
    /// 这次按键的读数算在哪一组。
    let phase: String

    /// 打常见的词（每个字都有命中，列表跟着换）、打几乎没有命中的词（要扫全表）、用拼音组字、删字，各一组读数。
    static let phases = ["common", "rare", "compose", "delete"]

    /// 每个词打完再逐字删掉，下一个词从空的搜索框开始。
    static let script: [SearchKey] = {
        func type(_ word: String, as phase: String) -> [SearchKey] {
            word.map { SearchKey(action: .insert(String($0)), phase: phase) }
        }
        func delete(_ count: Int) -> [SearchKey] {
            Array(repeating: SearchKey(action: .deleteBackward, phase: "delete"), count: count)
        }
        var keys = type("github", as: "common") + delete(6)
        keys += type("zqxj", as: "rare") + delete(4)
        keys += ["c", "ce", "ces", "cesh", "ceshi"].map { SearchKey(action: .mark($0), phase: "compose") }
        keys.append(SearchKey(action: .insert("测试"), phase: "common"))
        keys += delete(2)
        return keys
    }()

    /// 每行读数前面的标签：组别加上这次按的键。
    var label: String {
        switch action {
        case .insert(let text), .mark(let text): "\(phase)[\(text)]"
        case .deleteBackward: phase
        }
    }

    static func phase(of label: String) -> String {
        phases.first { label.hasPrefix($0) } ?? label
    }

    /// 搜索框不是第一响应者、按键送不到时返回 false。
    func send(to window: NSWindow) -> Bool {
        guard let editor = window.firstResponder as? NSTextView else { return false }
        switch action {
        case .insert(let text):
            editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        case .mark(let text):
            editor.setMarkedText(
                text, selectedRange: NSRange(location: text.utf16.count, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
        case .deleteBackward:
            editor.deleteBackward(nil)
        }
        return true
    }
}

/// 测删除时每帧调用一次 `PanelBenchmark.frameTick`。
@MainActor
private final class BenchTicker: NSObject {
    private let window: NSWindow
    private var link: CADisplayLink?

    init(window: NSWindow) {
        self.window = window
        super.init()
        link = window.contentView?.displayLink(target: self, selector: #selector(step))
        link?.isPaused = true
        link?.add(to: .main, forMode: .common)
    }

    func start() { link?.isPaused = false }
    func stop() { link?.isPaused = true }

    @objc private func step(_ link: CADisplayLink) {
        PanelBenchmark.frameTick(in: window)
    }
}

/// 面板内容图层里一个几乎透明的 2×2 Metal 图层。每帧提交一次画面，记录系统报告的实际上屏时间。
@MainActor
private final class PresentProbe {
    private let layer = CAMetalLayer()
    private let queue: MTLCommandQueue
    private var flip = false
    /// 一帧探针画面：在哪一帧 display link 时提交，什么时候上屏。
    struct Frame {
        var submitted: CFTimeInterval
        var presented: CFTimeInterval
    }
    private(set) var frames: [Frame] = []
    var presented: [CFTimeInterval] { frames.map(\.presented) }

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
        frames = []
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
        let submitted = CACurrentMediaTime()
        drawable.addPresentedHandler { [weak self] drawable in
            let time = drawable.presentedTime
            // presentedTime 为 0 表示这一帧没有上屏，例如面板已经离开屏幕。
            guard time > 0 else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.frames.append(Frame(submitted: submitted, presented: time)) }
            }
        }
        buffer.present(drawable)
        buffer.commit()
    }
}
#endif
