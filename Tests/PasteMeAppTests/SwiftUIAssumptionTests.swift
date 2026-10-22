import AppKit
import Observation
import QuartzCore
import SwiftUI
import Testing
@testable import PasteMeApp
import PasteMeCore

/// 在真实的 SwiftUI 里确认删除动画依赖的几条行为。`PanelFlushTests` 和 `PanelSimulator` 按这些行为模拟 SwiftUI，
/// `CardDust` 也按它们推算卡片在屏幕上的位置。这里的测试失败，说明 SwiftUI 或面板的视图结构变了，
/// 要先改模拟和 `CardDust`，再看其他测试。
///
/// 视图放在一个不显示的窗口里，测试在主线程上转几圈 run loop，让 SwiftUI 处理更新。
@MainActor
@Suite struct SwiftUIAssumptionTests {
    /// 转 run loop，直到 `condition` 成立或超过 `timeout` 秒。返回是否成立。
    @discardableResult
    func spin(timeout: Double = 0.5, until condition: () -> Bool = { false }) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }
        return condition()
    }

    // MARK: SwiftUI 的通用行为

    /// 进入 `withAnimation` 之前的改动会先单独渲染一次。所以 `HistoryModel` 要把视图可见的改动放在同一个
    /// `animate` 里，`PanelFlushTests` 检查这一点。
    @Test func changesBeforeWithAnimationAreRenderedOnTheirOwn() {
        let model = ProbeModel()
        var reported: [CGFloat] = []
        let window = Self.window(ProbeView(model: model) { id, x in if id == 3 { reported.append(x) } })
        spin(timeout: 0.2)
        reported = []

        model.items.insert(0, at: 0)
        withAnimation(.spring) { model.items.removeFirst() }
        spin(timeout: 0.2)

        // 插入 0 以后 3 被推到第 4 格（x = 180），哪怕紧接着又在 withAnimation 里删掉了 0。
        #expect(reported.contains(180), "报告过的位置：\(reported)")
        _ = window
    }

    // MARK: 面板（HistoryView）的行为

    /// 一个装着真实 `HistoryView` 的不显示的窗口。删除动画用 `FakeRemovalEffect` 控制，`CardDust` 只收位置报告。
    @MainActor
    struct Panel {
        let store: ClipStore
        let model: HistoryModel
        let effect = FakeRemovalEffect()
        let dust = CardDust()
        let window: NSWindow

        init(count: Int = 6) throws {
            store = try ClipStore(path: ":memory:")
            for i in 0..<count {
                try store.insert(ClipContent(kind: .text, text: "条目 \(i)"), source: nil, at: Date(timeIntervalSince1970: Double(i)))
            }
            model = HistoryModel(store: store)
            model.removalEffect = effect
            window = SwiftUIAssumptionTests.window(HistoryView(model: model, dust: dust), width: 1700, height: 330)
            model.didShow()
            model.focus = .cards
        }
    }

    /// 带动画的移动只报告终点，不报告动画途中的位置。`CardDust.visibleFrame` 按这一点自己算出途中的位置。
    /// （容器的大小或位置本身在做动画时不是这样，例如居中摆放、宽度在变的 `HStack` 会逐帧报告。）
    @Test func animatedSlidesReportOnlyTheFinalPosition() throws {
        let panel = try Panel()
        spin(timeout: 0.3)
        let moving = panel.model.items[2].id
        panel.model.delete()
        panel.model.delete()
        spin(timeout: 0.2)
        let before = try #require(panel.dust.frames[moving])

        panel.effect.finishDisappear()
        var seen: Set<CGFloat> = [before.minX]
        spin(timeout: 0.6) {
            if let x = panel.dust.frames[moving]?.minX { seen.insert(x) }
            return false
        }

        // 往左滑了两格，期间只报告过起点和终点。
        #expect(seen == [before.minX, before.minX - 2 * (ClipCardView.size.width + HistoryView.cardSpacing)], "报告过的位置：\(seen.sorted())")
    }

    /// 改了列表以后，新的布局位置在 `CardDust.slideWindow` 以内报上来，才会被当作这次滑动。
    @Test func newPositionsAreReportedWithinTheSlideWindow() throws {
        let panel = try Panel()
        spin(timeout: 0.3)
        let moving = panel.model.items[1].id
        panel.model.delete()
        spin(timeout: 0.2)
        let before = panel.dust.frames[moving]

        let start = CACurrentMediaTime()
        panel.effect.finishDisappear()
        let reported = spin(timeout: 1) { panel.dust.frames[moving] != before }

        #expect(reported)
        #expect(CACurrentMediaTime() - start < CardDust.slideWindow)
    }

    /// 撤销删除时插回来的卡片同时被选中：选中项和它的第一个布局位置在同一次更新里报上来，
    /// `CardDust` 据此认出它是刚出现的卡片，直接按放大后的大小算（SwiftUI 不给新视图做放大动画）。
    /// 卡片被去掉时要立即移除（`HistoryView.cardTransition`）：改成淡出的话，被去掉的视图在动画期间还在，
    /// 放回同一个条目时不是新视图，这个测试会失败。
    @Test func aNewlyInsertedSelectedCardIsReportedTogetherWithTheSelection() throws {
        let panel = try Panel()
        spin(timeout: 0.3)
        let restored = panel.model.items[0].id
        panel.model.delete()
        panel.effect.finishDisappear()
        spin(timeout: 0.3)
        #expect(panel.dust.frames[restored] == nil)

        panel.model.undoDelete()
        spin(timeout: 0.5) { panel.dust.firstLaidOut[restored] != nil }

        let laidOut = try #require(panel.dust.firstLaidOut[restored])
        #expect(abs(laidOut - panel.dust.lastSelectionChange) < CardDust.sameUpdate)
        #expect(panel.dust.scale(of: restored) == HistoryView.selectedScale)
    }

    /// ⌘1…⌘9 从第一张完整显示的卡片数起（#39）：滚动后 `HistoryView` 把它报给模型；重新呼出面板时滚回最前面。
    /// 这依赖滚动时 `onGeometryChange` 会重新计算卡片列表在滚动区域里的位置。
    @Test func scrollingReportsTheFirstFullyVisibleCard() throws {
        let panel = try Panel(count: 20)
        spin(timeout: 0.3)
        #expect(panel.model.firstVisibleCard == 0)

        // 用方向键选到后面的卡片。
        panel.model.selectedID = panel.model.items[15].id
        spin(timeout: 0.6)
        try expectFirstVisibleCard(in: panel)

        // 重新呼出面板时选中的还是这一条（又复制了一次，移到了最前），选中项不变，也要滚回最前面。
        let selected = try #require(panel.model.selectedID)
        try panel.store.touch(id: selected, at: Date(timeIntervalSince1970: 100))
        panel.model.didShow()
        #expect(panel.model.selectedID == selected)
        spin(timeout: 0.6)
        #expect(panel.model.firstVisibleCard == 0)
        #expect(panel.dust.frames[selected]?.minX == 30)
    }

    /// 模型记下的那张卡片完整显示，它左边那张没有。`CardDust` 记的位置以 `HistoryView` 的左边为准，就是滚动区域的左边。
    private func expectFirstVisibleCard(in panel: Panel) throws {
        let first = panel.model.firstVisibleCard
        try #require(first > 0)
        let cards = panel.model.cards
        let frame = try #require(panel.dust.frames[cards[first].id])
        #expect(frame.minX >= -0.5, "第一张完整显示的卡片在 \(frame.minX)")
        if let previous = panel.dust.frames[cards[first - 1].id] {
            #expect(previous.minX < -0.5, "左边那张在 \(previous.minX)")
        }
    }

    // MARK: 工具

    static func window(_ view: some View, width: CGFloat = 400, height: CGFloat = 100) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = NSHostingView(rootView: view)
        return window
    }
}

@Observable
@MainActor
private final class ProbeModel {
    var items = [1, 2, 3]
}

/// 和面板一样的结构：滚动视图里的 `LazyHStack`，每一格报告自己的位置。
private struct ProbeView: View {
    let model: ProbeModel
    let report: (Int, CGFloat) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 10) {
                ForEach(model.items, id: \.self) { item in
                    Color.gray.frame(width: 50, height: 50)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("probe")).minX } action: { report(item, $0) }
                }
            }
        }
        .coordinateSpace(.named("probe"))
    }
}
