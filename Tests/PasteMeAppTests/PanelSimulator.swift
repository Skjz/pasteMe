import Foundation
import QuartzCore
import SwiftUI
@testable import PasteMeApp
import PasteMeCore

/// 在虚拟时钟上模拟面板：真实的 `HistoryModel` 和 `CardDust`，加上一块按 SwiftUI 的规则算出来的「屏幕」。
///
/// 屏幕的规则（`SwiftUIAssumptionTests` 在真实的 SwiftUI 里验证它们）：
/// - 卡片按 `HistoryModel.cards` 的顺序排成一格一格；
/// - 模型的改动在下一帧由 SwiftUI 处理：这时屏幕上的动画开始，新的布局位置和选中项同时报给 `CardDust`
///   （`onGeometryChange`、`onChange`）；
/// - 在 `animate`（`withAnimation`）里带动画改动的位置，卡片从屏幕上的当前位置沿 `SpringCurve.slide` 滑到新位置，
///   几次滑动叠加；没有动画的改动直接跳过去；进入 `animate` 之前的改动先按没有动画处理；
/// - 选中项变化时卡片按 `SpringCurve.selection` 放大或缩回，新出现的卡片直接是目标大小。
///
/// 每一帧检查颗粒和卡片是否对齐、卡片有没有滑进颗粒的范围，以及空位是不是等所有颗粒播完才去掉，
/// 发现的问题记在 `problems` 里。
@MainActor
final class PanelSimulator {
    static let step = ClipCardView.size.width + HistoryView.cardSpacing
    static let frameDuration = 1.0 / 120
    /// 颗粒和卡片的位置允许差多少点、大小允许差多少。
    static let positionTolerance: CGFloat = 2
    static let scaleTolerance: CGFloat = 0.004
    /// 颗粒播放时，别的卡片最多能盖住它多少点；看得见的卡片之间也一样。`CardDust` 在别的卡片盖着
    /// 不到 12 点时就开始聚拢。
    static let overlapTolerance: CGFloat = 20

    let store: ClipStore
    let model: HistoryModel
    let dust = CardDust()
    private(set) var clock: CFTimeInterval = 1000
    private(set) var problems: [String] = []

    private var timers: [(fire: CFTimeInterval, action: @MainActor () -> Void)] = []

    // MARK: 屏幕上的卡片

    private struct Slide {
        var dx: CGFloat
        var start: CFTimeInterval
    }

    private struct ScaleChange {
        var from: CGFloat
        var to: CGFloat
        var start: CFTimeInterval
    }

    /// 布局位置（滑动的终点）。
    private var layout: [Int64: CGRect] = [:]
    private var slides: [Int64: [Slide]] = [:]
    private var scaleChanges: [Int64: ScaleChange] = [:]
    private var selected: Int64?
    /// 模型改了、SwiftUI 还没处理的状态：卡片的布局位置、选中项，以及这些改动带不带动画。
    private var pending: (layout: [Int64: CGRect], selected: Int64?, animated: Bool)?
    private var reportedLayout: [Int64: CGRect] = [:]

    /// 历史里放 `count` 条文本，打开面板，焦点放在卡片上。`inPinboard` 为 true 时把它们按从旧到新的顺序
    /// 固定到一个 Pinboard 里、切到这个标签：卡片按固定的位置排列，⌘⌫ 是从 Pinboard 里拿掉。
    static func make(count: Int = 12, inPinboard: Bool = false) async throws -> PanelSimulator {
        let pipeline = DustPipeline.shared
        pipeline.prepare()
        for _ in 0..<500 where pipeline.state == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try PanelSimulator(count: count, inPinboard: inPinboard)
    }

    private init(count: Int, inPinboard: Bool) throws {
        store = try ClipStore(path: ":memory:")
        let apps = [("com.apple.Notes", "备忘录"), ("com.apple.Safari", "Safari"), ("com.apple.Terminal", "终端")]
        for i in 0..<count {
            let app = apps[i % apps.count]
            try store.insert(
                ClipContent(kind: .text, text: "条目 \(i)"), source: ClipSource(bundleID: app.0, name: app.1),
                at: Date(timeIntervalSince1970: Double(i))
            )
        }
        model = HistoryModel(store: store)
        model.removalEffect = dust
        dust.now = { [unowned self] in clock }
        dust.schedule = { [unowned self] delay, action in timers.append((clock + delay, action)) }
        model.animate = { [unowned self] animation, body in
            // SwiftUI 进入 withAnimation 前先按没有动画渲染之前的改动。
            render(animated: false)
            let itemsBefore = model.items.map(\.id)
            let hadGaps = !model.gaps.isEmpty
            body()
            // 空位一起去掉、右边的卡片补位：这时不能还有颗粒在飘或卡片在聚拢（删除动画播完之前其他卡片不动）。
            if hadGaps, model.gaps.isEmpty, model.items.map(\.id) == itemsBefore,
               !dust.view.states.isEmpty || !model.hiddenIDs.isEmpty {
                problems.append("t=\(time) 还有颗粒在播放时，空位就去掉了，卡片开始补位")
            }
            render(animated: animation != nil)
        }
        model.didShow()
        if inPinboard {
            let pinboard = try store.createPinboard(name: "工作", color: .blue)
            let ids = try store.items().map(\.id).reversed()
            for id in ids { try store.pin(id, to: pinboard.id) }
            try store.setOrder(Array(ids), inPinboard: pinboard.id)
            model.reloadPinboards()
            model.showTab(pinboard.id)
        }
        model.focus = .cards
        render(animated: false)
        update()
    }

    // MARK: 操作

    /// ⌘⌫：删除选中的卡片。
    func deleteSelected() {
        model.delete()
        render(animated: false)
    }

    /// 右键菜单删除第 `position` 格的卡片（空位不算）。
    func delete(atPosition position: Int) {
        let cards = model.cards
        guard cards.indices.contains(position), !cards[position].isGap else { return }
        model.delete(cards[position].item)
        render(animated: false)
    }

    func undo() {
        model.undoDelete()
        render(animated: false)
    }

    func moveSelection(by offset: Int) {
        model.moveSelection(by: offset)
        render(animated: false)
    }

    /// 走 `seconds` 秒，每一帧检查一次。
    func wait(_ seconds: Double) {
        for _ in 0..<Int((seconds / Self.frameDuration).rounded(.up)) {
            tick()
        }
    }

    /// 等所有动画停下，检查最后的样子：没有空位、没有藏着的卡片、没有颗粒，卡片都在布局位置上。
    func settle() {
        wait(3)
        if !model.cards.allSatisfy({ !$0.isGap }) { problems.append("动画都结束了，还有空位：\(model.cards.map(\.id))") }
        if !model.hiddenIDs.isEmpty { problems.append("动画都结束了，还有卡片没显示：\(model.hiddenIDs)") }
        if !dust.view.states.isEmpty { problems.append("动画都结束了，还有颗粒：\(dust.view.states.keys.sorted())") }
        for (id, frame) in layout where abs(visibleFrame(id).minX - frame.minX) > 0.5 {
            problems.append("卡片 \(id) 停在 \(visibleFrame(id).minX)，布局位置是 \(frame.minX)")
        }
    }

    // MARK: 一帧

    private func tick() {
        clock += Self.frameDuration
        // 上一帧的改动这时由 SwiftUI 处理：屏幕上的动画开始，布局和选中项报给 CardDust。
        update()
        let due = timers.filter { $0.fire <= clock }
        timers.removeAll { $0.fire <= clock }
        for timer in due { timer.action() }
        dust.view.advance()
        render(animated: false)
        check()
    }

    /// 记下模型现在的状态，等 SwiftUI 处理。`animated` 表示这些改动是不是在带动画的 withAnimation 里。
    /// 同一帧里几次改动合在一起处理，只要有一次带动画，位置的变化就按动画处理。
    private func render(animated: Bool) {
        let cards = model.cards
        let ids = cards.map(\.id)
        if Set(ids).count != ids.count {
            problems.append("t=\(time) 同一个条目出现了两次：\(ids)")
        }
        var newLayout: [Int64: CGRect] = [:]
        for (position, card) in cards.enumerated() {
            newLayout[card.id] = CGRect(
                x: 30 + CGFloat(position) * Self.step, y: 64,
                width: ClipCardView.size.width, height: ClipCardView.size.height
            )
        }
        let base = pending?.layout ?? layout
        let movedNow = newLayout.contains { id, frame in base[id].map { $0.minX != frame.minX } ?? false }
        guard newLayout != base || model.selectedID != (pending?.selected ?? selected) || pending != nil else { return }
        pending = (newLayout, model.selectedID, (pending?.animated ?? false) || (animated && movedNow))
    }

    /// SwiftUI 处理一次更新。
    private func update() {
        guard let (newLayout, newSelected, animated) = pending else { return }
        pending = nil
        for (id, frame) in newLayout {
            guard let old = layout[id], old.minX != frame.minX else { continue }
            if animated {
                slides[id, default: []].append(Slide(dx: old.minX - frame.minX, start: clock))
            } else {
                slides[id] = nil
            }
        }
        for id in layout.keys where newLayout[id] == nil {
            slides[id] = nil
            scaleChanges[id] = nil
        }
        if newSelected != selected {
            for (id, target) in [(selected, 1.0), (newSelected, HistoryView.selectedScale)] {
                guard let id, newLayout[id] != nil else { continue }
                // 新出现的卡片直接是目标大小。
                guard layout[id] != nil else {
                    scaleChanges[id] = nil
                    continue
                }
                scaleChanges[id] = ScaleChange(from: visibleScale(id), to: target, start: clock)
            }
        }
        layout = newLayout
        selected = newSelected
        for (id, frame) in newLayout {
            dust.cardLaidOut(id, at: frame)
        }
        for id in reportedLayout.keys where newLayout[id] == nil {
            dust.cardLeft(id)
        }
        reportedLayout = newLayout
        dust.selectionChanged(to: newSelected)
    }

    // MARK: 屏幕上的样子

    func visibleFrame(_ id: Int64) -> CGRect {
        guard var frame = layout[id] else { return .null }
        for slide in slides[id] ?? [] {
            frame.origin.x += slide.dx * CGFloat(1 - SpringCurve.slide.progress(at: clock - slide.start))
        }
        return frame
    }

    func visibleScale(_ id: Int64) -> CGFloat {
        let settled = id == selected ? HistoryView.selectedScale : 1
        guard let change = scaleChanges[id] else { return settled }
        let t = clock - change.start
        guard t < SpringCurve.selection.settleTime else { return change.to }
        return change.to + (change.from - change.to) * CGFloat(1 - SpringCurve.selection.progress(at: t))
    }

    private var time: String { String(format: "%.3f", clock - 1000) }

    // MARK: 检查

    var trace = false
    private func check() {
        if trace {
            let cards = model.cards.map { "\($0.id)\($0.isGap ? "g" : "")\(model.hiddenIDs.contains($0.id) ? "h" : "")" }
            let dustStates = dust.view.states.map { "\($0.key)\($0.value.reverse ? "r" : "f"):x\(Int($0.value.frame.minX))s\(String(format: "%.3f", $0.value.scale))" }
            let vis = model.cards.map { "\($0.id):\(Int(visibleFrame($0.id).minX))s\(String(format: "%.3f", visibleScale($0.id)))" }
            print("[TRACE] t=\(time) sel=\(model.selectedID ?? -1) cards=\(cards) dust=\(dustStates) vis=\(vis.prefix(6))")
        }
        let cards = model.cards
        let visible = cards.filter { !$0.isGap && !model.hiddenIDs.contains($0.id) }.map(\.id)
        for (left, right) in zip(visible, visible.dropFirst()) {
            let overlap = visibleFrame(left).maxX - visibleFrame(right).minX
            if overlap > Self.overlapTolerance {
                problems.append("t=\(time) 卡片 \(right) 撞进了卡片 \(left) \(Int(overlap)) 点")
            }
        }
        for (id, state) in dust.view.states {
            // 卡片已经不在列表里（例如改了搜索词，空位去掉了），颗粒留在原处飘完。
            guard layout[id] != nil else { continue }
            let card = visibleFrame(id)
            if abs(state.frame.minX - card.minX) > Self.positionTolerance {
                problems.append("t=\(time) 卡片 \(id) 的颗粒在 \(Int(state.frame.minX))，卡片在 \(Int(card.minX))")
            }
            if state.reverse, abs(state.scale - visibleScale(id)) > Self.scaleTolerance {
                problems.append(String(format: "t=\(time) 卡片 \(id) 的颗粒放大 %.3f，卡片是 %.3f", state.scale, visibleScale(id)))
            }
            for other in visible where other != id {
                let overlap = min(state.frame.maxX, visibleFrame(other).maxX) - max(state.frame.minX, visibleFrame(other).minX)
                if overlap > Self.overlapTolerance {
                    problems.append("t=\(time) 卡片 \(other) 盖住了卡片 \(id) 的颗粒 \(Int(overlap)) 点")
                }
            }
        }
    }
}

/// 可重复的伪随机数（SplitMix64），随机场景测试用。
struct SeededGenerator: RandomNumberGenerator {
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
