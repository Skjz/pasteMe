import AppKit
import Metal
import PasteMeCore
import QuartzCore
import SwiftUI

/// 删除时卡片碎成颗粒向上飘散，撤销删除时颗粒飘回来拼成卡片。
///
/// 卡片先用 `ImageRenderer` 画成一张图，每个颗粒是图上 4×4 点的一块。颗粒的位置、大小和透明度都在
/// 着色器里按时间算出（`DustView`），主线程每帧只更新一个时间值、提交一次绘制。
@MainActor
final class CardDust: CardRemovalEffect {
    /// 卡片位置所用的坐标空间：`HistoryView` 的根视图。`DustView` 盖在根视图上，两者的坐标一致。
    nonisolated static let space = "HistoryView"

    let view = DustView()
    /// 各张卡片的布局位置（不含选中时的放大），由 `HistoryView` 通过 `cardLaidOut` / `cardLeft` 更新。
    /// 卡片正在滑动时，这是滑动的终点，屏幕上的位置见 `visibleFrame(of:)`。
    private(set) var frames: [Int64: CGRect] = [:]
    let timing = DustTiming()
    /// 测试时替换成虚拟的时钟，`DustView` 也跟着用它。
    var now: () -> CFTimeInterval = CACurrentMediaTime {
        didSet { view.now = now }
    }
    /// 过一段时间再执行，用来推迟聚拢的开始。测试时替换成按虚拟时钟执行。
    var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { action() }
        }
    }

    /// 撤销删除后等着开始聚拢的卡片。值每次递增，用来认出已经被取消的那次等待。
    private var pendingAppear: [Int64: Int] = [:]
    private var nextToken = 0

    /// 卡片还没走完的滑动：布局位置变了多少（旧位置减新位置），从什么时候开始。
    private struct Slide {
        var dx: CGFloat
        var start: CFTimeInterval
    }

    private var slides: [Int64: [Slide]] = [:]
    /// 最近一次交出补位或让位动画（`slideAnimation()`）的时间。之后不久报上来的布局变化就是这次动画。
    private var lastSlideAnimation = -CFTimeInterval.infinity
    /// 交出动画后多久以内的布局变化算作这次动画。SwiftUI 在下一两帧里报告新的布局位置。
    static let slideWindow = 0.2

    /// 选中的卡片，由 `HistoryView` 在选中项变化时告诉这里。
    private var selectedID: Int64?
    /// 还没停下的放大或缩回：从多大到多大，从什么时候开始。
    private struct ScaleChange {
        var from: CGFloat
        var to: CGFloat
        var start: CFTimeInterval
    }

    private var scaleChanges: [Int64: ScaleChange] = [:]
    /// 每张卡片第一次报上布局位置的时间，用来认出刚出现的卡片。
    private(set) var firstLaidOut: [Int64: CFTimeInterval] = [:]
    /// 最近一次收到选中项变化的时间。`SwiftUIAssumptionTests` 用它确认选中项和新卡片的位置在同一次更新里报上来。
    private(set) var lastSelectionChange = -CFTimeInterval.infinity
    /// 同一次 SwiftUI 更新里的几次回调，时间相差不超过这么多。
    static let sameUpdate = 0.004

    init() {
        view.scaleOf = { [weak self] id in self?.scale(of: id) ?? 1 }
        view.frameOf = { [weak self] id in self?.visibleFrame(of: id) }
    }

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func slideAnimation() -> Animation? {
        guard !Self.reduceMotion else { return .easeInOut(duration: 0.2) }
        lastSlideAnimation = now()
        return SpringCurve.slide.animation
    }

    /// 卡片的布局位置报上来了。刚交出过补位或让位动画时，位置的变化就是这次动画：记下来，
    /// 卡片在屏幕上从旧位置沿着弹簧滑过去，从现在开始。
    ///
    /// SwiftUI 处理这次更新时才开始播放动画，同时报告新的布局位置，可能比模型改列表晚一两帧。
    /// 所以滑动从报告的这一刻算起；也不在模型改列表时按格数记，那时布局还是旧的，偏移会被算两次。
    func cardLaidOut(_ id: Int64, at frame: CGRect) {
        let now = now()
        if let old = frames[id], old.minX != frame.minX, now - lastSlideAnimation < Self.slideWindow {
            slides[id, default: []].append(Slide(dx: old.minX - frame.minX, start: now))
        }
        if frames[id] == nil { firstLaidOut[id] = now }
        frames[id] = frame
    }

    /// 卡片离开了屏幕（被删掉、空位去掉，或者滚出了 `LazyHStack` 的范围）。
    func cardLeft(_ id: Int64) {
        frames[id] = nil
        slides[id] = nil
        firstLaidOut[id] = nil
    }

    /// 选中项变了：原来选中的卡片缩回，新选中的放大，和 `HistoryView` 里卡片的弹簧一样。
    /// 正在聚拢的颗粒按 `scale(of:)` 跟着变，拼好时和显示出来的卡片一样大。
    func selectionChanged(to id: Int64?) {
        let old = selectedID
        guard id != old else { return }
        let now = now()
        lastSelectionChange = now
        selectedID = id
        for (cardID, target) in [(old, 1.0), (id, HistoryView.selectedScale)] {
            guard let cardID else { continue }
            // 刚出现的卡片（这次更新才报上布局位置，或者还没报）直接是目标大小，SwiftUI 不给新视图做这个动画。
            // 例如面板打开时选中的第一张卡片。
            guard let appeared = firstLaidOut[cardID], now - appeared > Self.sameUpdate else {
                scaleChanges[cardID] = nil
                continue
            }
            scaleChanges[cardID] = ScaleChange(from: scale(of: cardID, selected: cardID == old), to: target, start: now)
        }
    }

    /// 卡片此刻放大的比例：选中的是 `HistoryView.selectedScale`，正在放大或缩回时按弹簧算出中间值。
    func scale(of id: Int64) -> CGFloat {
        scale(of: id, selected: id == selectedID)
    }

    private func scale(of id: Int64, selected: Bool) -> CGFloat {
        let settled = selected ? HistoryView.selectedScale : 1
        guard let change = scaleChanges[id] else { return settled }
        let t = now() - change.start
        guard t < SpringCurve.selection.settleTime else {
            scaleChanges[id] = nil
            return settled
        }
        return change.to + (change.from - change.to) * CGFloat(1 - SpringCurve.selection.progress(at: t))
    }

    /// 卡片此刻在屏幕上的位置。布局给的是滑动的终点，卡片还在滑的时候要加上没走完的那一段，
    /// 否则在补位途中删除，颗粒会出现在卡片前面一截的地方。
    func visibleFrame(of id: Int64) -> CGRect? {
        let now = now()
        slides[id]?.removeAll { now - $0.start >= SpringCurve.slide.settleTime }
        if slides[id]?.isEmpty == true { slides[id] = nil }
        return visibleFrame(of: id, at: now)
    }

    /// 卡片在 `time`（可以是将来）的位置，假定之后没有新的滑动。
    private func visibleFrame(of id: Int64, at time: CFTimeInterval) -> CGRect? {
        guard var frame = frames[id] else { return nil }
        for slide in slides[id] ?? [] where time - slide.start < SpringCurve.slide.settleTime {
            frame.origin.x += slide.dx * CGFloat(1 - SpringCurve.slide.progress(at: time - slide.start))
        }
        return frame
    }

    func playDisappear(
        _ item: ClipItem, shortcut: Int?, selected: Bool, searchText: String,
        completion: @escaping () -> Void
    ) -> Bool {
        // 撤销后还在等着开始聚拢的卡片：原来的颗粒还在飘的话，让它接着飘完，当作这次删除的动画；
        // 已经飘完了，这张卡片就一直没出现过，不用再播放。
        if pendingAppear.removeValue(forKey: item.id) != nil {
            return view.continueDisappearing(id: item.id, completion: completion)
        }
        guard !Self.reduceMotion, view.isReady, let frame = visibleFrame(of: item.id),
              let texture = texture(of: item, shortcut: shortcut, searchText: searchText)
        else { return false }
        view.play(
            id: item.id, texture: texture, frame: frame, scale: selected ? HistoryView.selectedScale : 1,
            reverse: false, timing: timing, completion: completion
        )
        return true
    }

    func playAppear(
        _ item: ClipItem, shortcut: Int?, searchText: String,
        completion: @escaping () -> Void
    ) -> Bool {
        // 卡片的图现在就画好：右边的卡片还没开始滑动，这几毫秒不会让动画掉帧。
        guard !Self.reduceMotion, view.isReady,
              let texture = texture(of: item, shortcut: shortcut, searchText: searchText)
        else { return false }
        nextToken += 1
        let token = nextToken
        pendingAppear[item.id] = token
        tryToStart(item.id, token: token, texture: texture, attempt: 0, completion: completion)
        return true
    }

    /// 颗粒要在卡片的位置上没有、接下来也不会有别的卡片挡着时才开始聚拢，否则会画在那张卡片上面，
    /// 变成一片碎块。卡片回到自己的空位时没有卡片挡着，马上开始，消失到一半时从当前的样子倒回去；
    /// 新插回来的卡片要等 SwiftUI 报上它的位置、右边的卡片让开。还不行就下一帧再看，最多等 `maxStartWait`。
    private func tryToStart(
        _ id: Int64, token: Int, texture: MTLTexture, attempt: Int, completion: @escaping () -> Void
    ) {
        guard pendingAppear[id] == token else { return }
        let waited = Double(attempt) * Self.frameDuration
        if let frame = visibleFrame(of: id), !isCovered(frame, except: id) || waited >= Self.maxStartWait {
            pendingAppear[id] = nil
            view.play(
                id: id, texture: texture, frame: frame, scale: scale(of: id),
                reverse: true, timing: timing, completion: completion
            )
        } else if waited >= Self.maxStartWait {
            // 一直没有位置：卡片不在屏幕上（例如已经滚到别处），直接显示。
            pendingAppear[id] = nil
            completion()
        } else {
            schedule(Self.frameDuration) { [weak self] in
                self?.tryToStart(id, token: token, texture: texture, attempt: attempt + 1, completion: completion)
            }
        }
    }

    private static let frameDuration = 1.0 / 120
    /// 撤销后最多等多久再开始聚拢。右边的卡片让开一般要 0.25 秒，正在滑动的卡片停下最多要 1 秒。
    private static let maxStartWait = 1.2
    /// 别的卡片还盖着这么多点以内，就算已经让开。
    private static let coverTolerance: CGFloat = 12

    /// `frame` 现在或者接下来会不会被别的卡片盖住。正在滑动的卡片可能冲过终点再弹回来
    /// （滑到一半又改了终点时，它带着原来的速度），所以沿着剩下的轨迹每隔一帧看一次。
    private func isCovered(_ frame: CGRect, except id: Int64) -> Bool {
        let now = now()
        let steps = Int(SpringCurve.slide.settleTime / Self.frameDuration)
        return frames.keys.contains { other in
            guard other != id else { return false }
            let horizon = slides[other] == nil ? 0 : steps
            return (0...horizon).contains { step in
                guard let rect = visibleFrame(of: other, at: now + Double(step) * Self.frameDuration) else { return false }
                return min(rect.maxX, frame.maxX) - max(rect.minX, frame.minX) > Self.coverTolerance
            }
        }
    }

    func cancelAll() {
        pendingAppear = [:]
        slides = [:]
        scaleChanges = [:]
        view.cancelAll()
    }

    /// 卡片现在的样子，和面板上的一样：同样的外观（深色或浅色）、⌘n 提示和搜索命中。
    private func texture(of item: ClipItem, shortcut: Int?, searchText: String) -> MTLTexture? {
        let appearance = view.effectiveAppearance
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let card = ClipCardView(item: item, shortcutIndex: shortcut, searchText: searchText)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: card)
        renderer.scale = view.window?.backingScaleFactor ?? 2
        renderer.isOpaque = false
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance { image = renderer.cgImage }
        return image.flatMap(DustPipeline.shared.texture(from:))
    }
}

/// 面板里卡片用的两种弹簧。SwiftUI 的 `.spring(response:dampingFraction:)` 就是这个阻尼振子，
/// 所以能按公式算出卡片在动画途中走到了哪里，让颗粒和卡片对齐。
struct SpringCurve {
    let response: Double
    let dampingFraction: Double

    /// 卡片补位和让位。几个空位一起去掉时卡片一次滑过好几格，回弹要小于卡片间距（18 点），
    /// 否则会撞进左边的卡片再弹回来：阻尼 0.86 时冲过终点不到 1%，滑十格也只有十几点。
    static let slide = SpringCurve(response: 0.32, dampingFraction: 0.86)
    /// 光标在卡片之间滑动，比卡片的滑动多一点弹性。卡片补位时光标跟着卡片用 `slide`。
    static let cursor = SpringCurve(response: 0.32, dampingFraction: 0.72)
    /// 卡片选中时放大、取消选中时缩回（`HistoryView.cardView`）。
    static let selection = SpringCurve(response: 0.28, dampingFraction: 0.7)

    var animation: Animation {
        .spring(response: response, dampingFraction: dampingFraction)
    }

    private var omega: Double { 2 * Double.pi / response }
    private var decay: Double { dampingFraction * omega }

    /// 过了这么久按已经停下处理，剩下的不到百万分之一：卡片一次滑过好几格（上千点）时，剩下的也不到一点。
    var settleTime: Double { log(1_000_000) / decay }

    /// 开始后 `t` 秒走完的比例：从 0 到 1，中途会略微超过 1 再回来。
    func progress(at t: Double) -> Double {
        guard t > 0 else { return 0 }
        let damped = omega * (1 - dampingFraction * dampingFraction).squareRoot()
        return 1 - exp(-decay * t) * (cos(damped * t) + decay / damped * sin(damped * t))
    }
}

/// 颗粒动画的节奏。着色器只用这里传进去的数值，调整节奏只改这里。
struct DustTiming: Equatable {
    /// 颗粒的边长（点）。
    var tile: Float = 4
    /// 从卡片左边扫到右边的时间：越靠右的颗粒越晚开始飘。
    var sweep: Float = 0.36
    /// 每个颗粒开始时间的随机推迟，上限。
    var jitter: Float = 0.14
    /// 越靠上的颗粒越早开始，最上面一行比最下面早这么多。
    var rowSkew: Float = 0.04
    /// 一个颗粒从开始飘到完全消失的时间，在这个范围内随机。
    var lifeMin: Float = 0.55
    var lifeMax: Float = 0.9
    /// 撤销删除时倒放的速度。
    var reverseSpeed = 1.5

    /// 最后一个颗粒消失的时刻。
    var duration: Double { Double(sweep + jitter + rowSkew + lifeMax) }

    /// 从开始到播放完需要的时间。
    func playLength(reverse: Bool) -> Double {
        reverse ? duration / reverseSpeed : duration
    }

    /// 开始后 `elapsed` 秒时传给着色器的时间：正放从 0 走到 `duration`，倒放从 `duration` 回到 0。
    func shaderTime(elapsed: Double, reverse: Bool) -> Double {
        let elapsed = min(max(elapsed, 0), playLength(reverse: reverse))
        return reverse ? duration - elapsed * reverseSpeed : elapsed
    }
}

/// 盖在面板内容上面的透明 Metal 视图，画正在播放的颗粒动画。几次删除可以同时播放，各画各的。
@MainActor
final class DustView: NSView {
    private struct Effect {
        var id: Int64
        var texture: MTLTexture
        /// 开始时卡片的位置和大小（点），不含选中时的放大。播放中按 `frameOf` 更新。
        var frame: CGRect
        var scale: CGFloat
        var reverse: Bool
        var timing: DustTiming
        var seed: UInt32
        var start: CFTimeInterval
        var completion: () -> Void

        func isFinished(at now: CFTimeInterval) -> Bool {
            now - start >= timing.playLength(reverse: reverse)
        }
    }

    /// 一个颗粒动画此刻画在哪里、多大、播放到哪里。测试按它检查颗粒和卡片是否对齐。
    struct State: Equatable {
        var frame: CGRect
        var scale: CGFloat
        var reverse: Bool
        /// 着色器时间，见 `DustTiming.shaderTime`。
        var time: Double
    }

    /// 测试时替换成虚拟的时钟（由 `CardDust.now` 设置）。
    var now: () -> CFTimeInterval = CACurrentMediaTime
    private var effects: [Int64: Effect] = [:]
    private var displayLink: CADisplayLink?
    /// 聚拢中的卡片此刻放大的比例。拼好之前选中项可能变了，颗粒要跟着卡片缩回或放大；
    /// 飘散中的卡片已经删掉，一直用开始时的比例。
    var scaleOf: ((Int64) -> CGFloat)?
    /// 卡片此刻在屏幕上的位置。聚拢途中可能又撤销了一张插在它前面的卡片，它被挤着往右滑，颗粒要跟着走。
    /// 找不到时（卡片已经不在屏幕上）用开始时的位置。
    var frameOf: ((Int64) -> CGRect?)?

    private var metalLayer: CAMetalLayer {
        layer as! CAMetalLayer
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = DustPipeline.shared.device
        layer.pixelFormat = .bgra8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.isOpaque = false
        layer.framebufferOnly = true
        // 没有动画时不参与合成。
        layer.isHidden = true
        return layer
    }

    override var isFlipped: Bool { true }

    /// 颗粒只是画面，鼠标点击落到下面的卡片上。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 着色器已经编译好。还没好时（启动后极短的时间内）删除不播放动画。
    var isReady: Bool { DustPipeline.shared.state != nil }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    /// 开始播放一张卡片的动画，并且马上画出第一帧。同一张卡片已经在播放时，换成这一次，
    /// 从当前的样子接着播：消失到一半时倒放，颗粒从当前位置飘回去；拼到一半时删除，从当前位置散开。
    /// - Parameters:
    ///   - texture: 卡片的图，见 `DustPipeline.texture(from:)`。
    ///   - frame: 卡片的位置（点，左上角为原点），不含选中时的放大。
    ///   - scale: 卡片绕中心放大的比例，选中的卡片是 `HistoryView.selectedScale`。
    ///   - reverse: 倒放，颗粒从四周飘回来拼成卡片。
    ///   - completion: 播放完后调用；被 `cancelAll()` 或同一张卡片的下一次动画取代时不调用。
    func play(
        id: Int64, texture: MTLTexture, frame: CGRect, scale: CGFloat, reverse: Bool, timing: DustTiming,
        completion: @escaping () -> Void
    ) {
        let now = now()
        var start = now
        if let running = effects[id], running.reverse != reverse {
            // 消失到一半撤销、或者拼到一半又删除：从当前的样子接着播，不跳回开头。
            let current = running.timing.shaderTime(elapsed: now - running.start, reverse: running.reverse)
            start = reverse ? now - (timing.duration - current) / timing.reverseSpeed : now - current
        }
        effects[id] = Effect(
            id: id, texture: texture, frame: frame, scale: scale, reverse: reverse, timing: timing,
            seed: UInt32(truncatingIfNeeded: id &* 2_654_435_761), start: start,
            completion: completion
        )
        metalLayer.isHidden = false
        draw()
        startDisplayLink()
    }

    /// 这张卡片的颗粒正在飘散时，让它接着飘完，播完调用新的 `completion`。没有在飘散时返回 false。
    func continueDisappearing(id: Int64, completion: @escaping () -> Void) -> Bool {
        guard let effect = effects[id], !effect.reverse else { return false }
        effects[id]?.completion = completion
        return true
    }

    /// 停掉所有动画，不调用它们的 completion。
    func cancelAll() {
        guard !effects.isEmpty else { return }
        effects = [:]
        draw()
        stop()
    }

    private func startDisplayLink() {
        if displayLink == nil {
            let link = displayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    private func stop() {
        displayLink?.isPaused = true
        metalLayer.isHidden = true
    }

    @objc private func step(_ link: CADisplayLink) {
        advance()
    }

    /// 走一帧：去掉播完的动画，画出这一帧，再调用播完的动画的 completion。display link 每帧调用；
    /// 测试推进虚拟时钟后直接调用。
    func advance() {
        let now = now()
        let finished = effects.filter { $0.value.isFinished(at: now) }
        for id in finished.keys { effects[id] = nil }
        // 最后一帧画完再隐藏：画的是空白，下次显示时不会先闪出上一次的残影。
        draw()
        if effects.isEmpty { stop() }
        for effect in finished.values { effect.completion() }
    }

    /// 正在播放的各个动画此刻的样子。`draw()` 按它画，测试按它检查。
    var states: [Int64: State] {
        let now = now()
        return effects.mapValues { effect in
            State(
                frame: frameOf?(effect.id) ?? effect.frame,
                scale: effect.reverse ? scaleOf?(effect.id) ?? effect.scale : effect.scale,
                reverse: effect.reverse,
                time: effect.timing.shaderTime(elapsed: now - effect.start, reverse: effect.reverse)
            )
        }
    }

    private func draw() {
        let pipeline = DustPipeline.shared
        guard bounds.width > 0, bounds.height > 0,
              let drawable = metalLayer.nextDrawable(),
              let buffer = pipeline.queue?.makeCommandBuffer()
        else { return }
        let states = states
        let frames = effects.compactMap { id, effect -> DustFrame? in
            guard let state = states[id] else { return nil }
            return DustFrame(
                texture: effect.texture, frame: state.frame, scale: state.scale, timing: effect.timing,
                time: state.time, seed: effect.seed
            )
        }
        guard pipeline.encode(frames, viewSize: bounds.size, into: drawable.texture, on: buffer) else { return }
        buffer.present(drawable)
        buffer.commit()
    }
}

/// 一个颗粒动画在某一时刻的样子：哪张卡片、在哪里、播放到第几秒。
struct DustFrame {
    var texture: MTLTexture
    /// 卡片的位置和大小（点，左上角为原点），不含选中时的放大。
    var frame: CGRect
    var scale: CGFloat
    var timing: DustTiming
    /// 着色器时间，见 `DustTiming.shaderTime`。
    var time: Double
    var seed: UInt32
}

/// 着色器的参数，字段顺序和类型要与 `DustPipeline.source` 里的 `DustUniforms` 一致。
private struct DustUniforms {
    var viewSize: SIMD2<Float>
    var origin: SIMD2<Float>
    var cardSize: SIMD2<Float>
    var scale: Float
    var time: Float
    var tile: Float
    var sweep: Float
    var jitter: Float
    var rowSkew: Float
    var lifeMin: Float
    var lifeMax: Float
    var columns: UInt32
    var seed: UInt32
}

/// Metal 设备、着色器和采样器，整个应用共用一份。着色器源码在运行时编译（SwiftPM 不编译 .metal 文件），
/// 由 `prepare()` 在启动时放到后台进行，约几十毫秒。
@MainActor
final class DustPipeline {
    static let shared = DustPipeline()

    let device: MTLDevice?
    let queue: MTLCommandQueue?
    let sampler: MTLSamplerState?
    private(set) var state: MTLRenderPipelineState?
    private var compiling = false

    private init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        sampler = device?.makeSamplerState(descriptor: descriptor)
    }

    /// 应用启动时调用一次，在后台编译着色器。
    func prepare() {
        guard state == nil, !compiling, let device else { return }
        compiling = true
        Task {
            let state = await Task.detached(priority: .utility) { Self.compile(device) }.value
            self.state = state
            self.compiling = false
        }
    }

    nonisolated private static func compile(_ device: MTLDevice) -> MTLRenderPipelineState? {
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "dust_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "dust_fragment")
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = .bgra8Unorm
            // 贴图是预乘过透明度的。
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .one
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("PasteMe: 编译颗粒动画的着色器失败：\(error)")
            return nil
        }
    }

    /// 先清空 `target`，再把各个颗粒动画画上去。`viewSize` 是 `target` 对应的视图大小（点）。
    /// 着色器还没编译好时返回 false。
    func encode(_ frames: [DustFrame], viewSize: CGSize, into target: MTLTexture, on buffer: MTLCommandBuffer) -> Bool {
        guard let state else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(state)
        encoder.setFragmentSamplerState(sampler, index: 0)
        for frame in frames {
            let timing = frame.timing
            let columns = UInt32((Float(frame.frame.width) / timing.tile).rounded(.up))
            let rows = UInt32((Float(frame.frame.height) / timing.tile).rounded(.up))
            var uniforms = DustUniforms(
                viewSize: SIMD2(Float(viewSize.width), Float(viewSize.height)),
                origin: SIMD2(Float(frame.frame.minX), Float(frame.frame.minY)),
                cardSize: SIMD2(Float(frame.frame.width), Float(frame.frame.height)),
                scale: Float(frame.scale),
                time: Float(frame.time),
                tile: timing.tile,
                sweep: timing.sweep,
                jitter: timing.jitter,
                rowSkew: timing.rowSkew,
                lifeMin: timing.lifeMin,
                lifeMax: timing.lifeMax,
                columns: columns,
                seed: frame.seed
            )
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<DustUniforms>.stride, index: 0)
            encoder.setFragmentTexture(frame.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: Int(columns * rows))
        }
        encoder.endEncoding()
        return true
    }

    /// 把卡片的图片转成贴图：sRGB、预乘透明度、第一行是图片的最上面一行。
    func texture(from image: CGImage) -> MTLTexture? {
        let width = image.width, height = image.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device?.makeTexture(descriptor: descriptor),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)
        return texture
    }

    /// 每个颗粒是一个实例，画成两个三角形。颗粒的随机参数由序号和 `seed` 算出，CPU 不用逐个准备。
    nonisolated private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct DustUniforms {
        float2 viewSize;
        float2 origin;
        float2 cardSize;
        float scale;
        float time;
        float tile;
        float sweep;
        float jitter;
        float rowSkew;
        float lifeMin;
        float lifeMax;
        uint columns;
        uint seed;
    };

    struct DustVertex {
        float4 position [[position]];
        float2 uv;
        float alpha;
    };

    // 0..1 之间的伪随机数。
    static float random01(uint index, uint seed, uint salt) {
        uint n = index * 747796405u + seed * 2891336453u + salt * 277803737u;
        n = ((n >> ((n >> 28u) + 4u)) ^ n) * 277803737u;
        n = (n >> 22u) ^ n;
        return float(n) / 4294967295.0;
    }

    constant float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(1, 0), float2(1, 1), float2(0, 1)
    };

    vertex DustVertex dust_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                  constant DustUniforms &u [[buffer(0)]]) {
        float2 cell = float2(iid % u.columns, iid / u.columns) * u.tile;
        // 最右一列和最下一行可能不满一格，只取卡片以内的部分。
        float2 size = min(float2(u.tile), u.cardSize - cell);

        float delay = cell.x / u.cardSize.x * u.sweep
            + random01(iid, u.seed, 1) * u.jitter
            + (1.0 - cell.y / u.cardSize.y) * u.rowSkew;
        float life = mix(u.lifeMin, u.lifeMax, random01(iid, u.seed, 2));
        float local = clamp((u.time - delay) / life, 0.0, 1.0);
        float eased = local * local * (3.0 - 2.0 * local);

        // 向上飘（y 向下为正），略偏右，途中左右摆动一下。
        float2 drift = float2(mix(-18.0, 70.0, random01(iid, u.seed, 3)),
                              mix(-150.0, -40.0, random01(iid, u.seed, 4)));
        float swirl = mix(-24.0, 24.0, random01(iid, u.seed, 5));
        float2 corner = corners[vid];
        float2 point = cell + drift * eased + float2(sin(local * M_PI_F) * swirl, 0.0)
            + corner * size * (1.0 - 0.45 * local);

        // 选中的卡片绕中心放大。
        float2 center = u.cardSize * 0.5;
        point = u.origin + center + (point - center) * u.scale;

        DustVertex out;
        out.position = float4(point.x / u.viewSize.x * 2.0 - 1.0, 1.0 - point.y / u.viewSize.y * 2.0, 0.0, 1.0);
        out.uv = (cell + corner * size) / u.cardSize;
        out.alpha = local >= 1.0 ? 0.0 : 1.0 - pow(local, 1.4);
        return out;
    }

    fragment float4 dust_fragment(DustVertex in [[stage_in]],
                                  texture2d<float> card [[texture(0)]],
                                  sampler linear [[sampler(0)]]) {
        return card.sample(linear, in.uv) * in.alpha;
    }
    """
}

/// 把 `DustView` 放进 SwiftUI 的视图层级，盖在面板内容上面。
struct DustOverlay: NSViewRepresentable {
    let view: DustView

    func makeNSView(context: Context) -> DustView { view }

    func updateNSView(_ nsView: DustView, context: Context) {}
}
