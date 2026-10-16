import AppKit
import QuartzCore

/// 阻尼弹簧的参数，含义和 SwiftUI 的 `.spring(response:dampingFraction:)` 相同。
struct Spring: Equatable {
    /// 无阻尼时振动一个周期的秒数，越小越快。
    var response: Double
    /// 1 为临界阻尼（不回弹），小于 1 会回弹。
    var dampingFraction: Double

    /// 呼出：轻微回弹，约 0.3 秒到位。
    static let show = Spring(response: 0.3, dampingFraction: 0.78)
    /// 收起：不回弹，约 0.17 秒。
    static let hide = Spring(response: 0.16, dampingFraction: 1)
    /// 开启「减少动态效果」时，只做淡入淡出，也不回弹。
    static let fade = Spring(response: 0.2, dampingFraction: 1)
}

/// 面板的进度（0 为收起，1 为就位）随时间的变化，按弹簧的解析解计算。
///
/// 从任意进度和速度出发，所以动画进行到一半改变方向时，面板从当前位置平滑地折返。
struct PanelMotion: Equatable {
    var spring: Spring
    var from: Double
    var target: Double
    /// 起始速度，单位：进度 / 秒。
    var velocity: Double

    /// 经过 `t` 秒后的进度和速度。
    func state(at t: Double) -> (progress: Double, velocity: Double) {
        let omega = 2 * Double.pi / spring.response
        let zeta = spring.dampingFraction
        let x0 = from - target
        let v0 = velocity
        let x: Double
        let v: Double
        if zeta < 1 {
            let omegaD = omega * (1 - zeta * zeta).squareRoot()
            let decay = exp(-zeta * omega * t)
            let a = x0
            let b = (v0 + zeta * omega * x0) / omegaD
            let cosine = cos(omegaD * t)
            let sine = sin(omegaD * t)
            x = decay * (a * cosine + b * sine)
            v = decay * ((b * omegaD - zeta * omega * a) * cosine - (a * omegaD + zeta * omega * b) * sine)
        } else {
            let decay = exp(-omega * t)
            let b = v0 + omega * x0
            x = (x0 + b * t) * decay
            v = (b - omega * (x0 + b * t)) * decay
        }
        return (target + x, v)
    }

    /// 离终点和速度都足够小，可以直接停在终点。`tolerance` 是进度的允许误差。
    func isSettled(at t: Double, tolerance: Double) -> Bool {
        let (progress, velocity) = state(at: t)
        return abs(progress - target) < tolerance && abs(velocity) < tolerance * 10
    }
}

/// 按 `PanelMotion` 逐帧移动面板窗口、改变透明度。
///
/// 移动的是窗口本身而不是内容视图，这样毛玻璃背景和窗口阴影跟着一起动。
@MainActor
final class PanelAnimator: NSObject {
    private let window: NSWindow
    /// 面板就位时的窗口位置。
    var shownFrame: NSRect = .zero
    private(set) var progress: Double = 0

    private var motion: PanelMotion?
    private var startTime: CFTimeInterval = 0
    private var completion: (() -> Void)?
    /// 正在驱动动画的 display link。
    private var displayLink: CADisplayLink?
    /// 每个显示器一个 display link，不用时暂停而不销毁：第一次创建要读取显示器的模式列表，约 0.2 秒。
    private var links: [CGDirectDisplayID: CADisplayLink] = [:]

    init(window: NSWindow) {
        self.window = window
    }

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// 从当前进度和速度出发，动画到 `target`（0 或 1）。正在进行的动画被替换，它的完成回调不再调用。
    func animate(to target: Double, spring: Spring, completion: @escaping () -> Void) {
        let now = CACurrentMediaTime()
        let velocity = motion.map { $0.state(at: now - startTime).velocity } ?? 0
        motion = PanelMotion(
            spring: Self.reduceMotion ? .fade : spring,
            from: progress,
            target: target,
            velocity: velocity
        )
        startTime = now
        self.completion = completion

        guard let screen = window.screen ?? NSScreen.main, let link = link(for: screen) else { return }
        if displayLink !== link { displayLink?.isPaused = true }
        link.isPaused = false
        displayLink = link
    }

    /// 应用启动时调用，提前为各个显示器创建 display link，第一次呼出面板时就不会卡顿。
    func prepare() {
        for screen in NSScreen.screens {
            _ = link(for: screen)
        }
    }

    private func link(for screen: NSScreen) -> CADisplayLink? {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        if let link = links[id] { return link }
        let link = screen.displayLink(target: self, selector: #selector(step))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        links[id] = link
        return link
    }

    /// 不做动画，直接放到某个进度。
    func jump(to progress: Double) {
        stop()
        apply(progress)
    }

    @objc private func step(_ link: CADisplayLink) {
        guard link === displayLink else { return }
        guard let motion else { return stop() }
        let t = CACurrentMediaTime() - startTime
        // 进度 1 对应窗口移动约 340 点，0.001 不到半个点。
        if motion.isSettled(at: t, tolerance: 0.001) {
            apply(motion.target)
            finish()
        } else {
            apply(motion.state(at: t).progress)
        }
    }

    private func finish() {
        let done = completion
        stop()
        done?()
    }

    private func stop() {
        displayLink?.isPaused = true
        displayLink = nil
        motion = nil
        completion = nil
    }

    private func apply(_ progress: Double) {
        self.progress = progress
        // 淡入比位移快一些，面板露出一半时已经基本不透明。
        window.alphaValue = CGFloat(min(max(progress * 1.6, 0), 1))
        // 开启「减少动态效果」时不移动，只做淡入淡出。
        let distance = Self.reduceMotion ? 0 : shownFrame.height + PanelController.margin
        var origin = shownFrame.origin
        origin.y -= CGFloat(1 - progress) * distance
        window.setFrameOrigin(origin)
    }
}
