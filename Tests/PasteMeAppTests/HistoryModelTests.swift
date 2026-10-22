import Foundation
import SwiftUI
import Testing
@testable import PasteMeApp
import PasteMeCore

@MainActor
@Suite struct HistoryModelTests {
    let store: ClipStore
    let model: HistoryModel
    /// 历史里从新到旧的 id：c、b、a。
    let c, b, a: Int64

    init() throws {
        store = try ClipStore(path: ":memory:")
        a = try store.insert(ClipContent(kind: .text, text: "a"), source: nil, at: Date(timeIntervalSince1970: 1))
        b = try store.insert(ClipContent(kind: .text, text: "b"), source: nil, at: Date(timeIntervalSince1970: 2))
        c = try store.insert(ClipContent(kind: .text, text: "c"), source: nil, at: Date(timeIntervalSince1970: 3))
        model = HistoryModel(store: store)
        model.didShow()
    }

    @Test func showingPanelSelectsNewestItem() {
        #expect(model.items.map(\.id) == [c, b, a])
        #expect(model.selectedID == c)
    }

    @Test func moveSelectionStepsThroughItems() {
        model.moveSelection(by: 1)
        #expect(model.selectedID == b)
        model.moveSelection(by: 1)
        #expect(model.selectedID == a)
        model.moveSelection(by: -1)
        #expect(model.selectedID == b)
    }

    @Test func moveSelectionStopsAtEnds() {
        model.moveSelection(by: -1)
        #expect(model.selectedID == c)
        model.moveSelection(by: 10)
        #expect(model.selectedID == a)
        model.moveSelection(by: 1)
        #expect(model.selectedID == a)
    }

    @Test func moveSelectionOnEmptyHistoryDoesNothing() throws {
        let empty = HistoryModel(store: try ClipStore(path: ":memory:"))
        empty.didShow()
        empty.moveSelection(by: 1)
        #expect(empty.selectedID == nil)
    }

    @Test func deletingSelectedItemSelectsTheOneThatTakesItsPlace() throws {
        model.moveSelection(by: 1)
        model.delete()

        #expect(model.items.map(\.id) == [c, a])
        #expect(model.selectedID == a)
        #expect(try store.count() == 2)
    }

    @Test func deletingLastItemSelectsNewLast() {
        model.moveSelection(by: 2)
        model.delete()

        #expect(model.items.map(\.id) == [c, b])
        #expect(model.selectedID == b)
    }

    @Test func deletingOnlyItemClearsSelection() {
        model.delete(model.items[0])
        model.delete(model.items[0])
        model.delete()

        #expect(model.items.isEmpty)
        #expect(model.selectedID == nil)
    }

    @Test func searchKeepsSelectionWhenStillListedOtherwiseSelectsFirst() {
        model.moveSelection(by: 1)
        model.query = "b"
        model.reload()
        #expect(model.selectedID == b)

        model.query = "a"
        model.reload()
        #expect(model.selectedID == a)
    }

    @Test func undoDeleteRestoresItemInPlaceAndSelectsIt() {
        model.moveSelection(by: 1)
        model.delete()
        #expect(model.canUndoDelete)

        model.undoDelete()

        #expect(model.items.map(\.id) == [c, b, a])
        #expect(model.selectedID == b)
        #expect(!model.canUndoDelete)
    }

    @Test func undoDeleteRestoresInReverseOrder() {
        model.delete()
        model.delete()
        #expect(model.items.map(\.id) == [a])

        model.undoDelete()
        #expect(model.items.map(\.id) == [b, a])
        model.undoDelete()
        #expect(model.items.map(\.id) == [c, b, a])
        #expect(model.selectedID == c)
    }

    @Test func filtersCombineWithTypedConditionsAndReloadImmediately() throws {
        let store = try ClipStore(path: ":memory:")
        let notes = ClipSource(bundleID: "com.apple.Notes", name: "备忘录")
        let safari = ClipSource(bundleID: "com.apple.Safari", name: "Safari")
        let day: TimeInterval = 24 * 3600
        let now = Date(timeIntervalSince1970: 100 * day + 12 * 3600)
        let noteLink = try store.insert(ClipContent(kind: .link, text: "https://notes.example"), source: notes, at: now)
        let oldLink = try store.insert(ClipContent(kind: .link, text: "https://old.example"), source: notes, at: now - 3 * day)
        let safariLink = try store.insert(ClipContent(kind: .link, text: "https://safari.example"), source: safari, at: now)
        let noteText = try store.insert(ClipContent(kind: .text, text: "note"), source: notes, at: now)
        let model = HistoryModel(store: store) { now }
        model.didShow()

        model.filters.kinds = [.link]
        #expect(Set(model.items.map(\.id)) == [noteLink, oldLink, safariLink])

        model.filters.sourceApp = SourceApp(bundleID: "com.apple.Notes", name: "备忘录", count: 3)
        #expect(Set(model.items.map(\.id)) == [noteLink, oldLink])

        model.filters.timeRange = .last7Days
        model.query = "old"
        #expect(model.items.map(\.id) == [oldLink])

        // 搜索框里的类型和按钮选的类型取交集。
        model.query = "type:text"
        #expect(model.items.isEmpty)
        #expect(model.activeConditions == ["类型条件没有交集", "来自备忘录", "最近 7 天"])

        model.filters.kinds = []
        #expect(model.items.map(\.id) == [noteText])
    }

    @Test func clearingSearchAlsoClearsFilters() {
        model.filters.kinds = [.image]
        model.query = "x"
        #expect(!model.searchIsEmpty)

        model.clearSearch()

        #expect(model.searchIsEmpty)
        #expect(model.items.map(\.id) == [c, b, a])
    }

    @Test func activeConditionsDescribeEverySearchCondition() {
        model.filters.timeRange = .today
        model.query = "发票 app:微信 type:图片"

        #expect(model.activeConditions == ["类型为图片", "来源应用的名字或别名包含“微信”", "今天", "包含“发票”"])
    }

    @Test func reopeningPanelClearsSearchAndFilters() {
        model.query = "a"
        model.filters.kinds = [.file]
        model.filters.timeRange = .yesterday

        model.didShow()

        #expect(model.query.isEmpty)
        #expect(model.filters == PanelFilters())
        #expect(model.items.map(\.id) == [c, b, a])
    }

    @Test func reopeningPanelForgetsDeletionsAndPutsFocusOnCards() {
        model.delete()
        model.focus = .search

        model.didShow()

        #expect(!model.canUndoDelete)
        #expect(model.focus == .cards)
    }

    @Test func deletingLeavesAGapUntilTheDisappearEffectFinishes() {
        let effect = FakeRemovalEffect()
        model.removalEffect = effect
        model.moveSelection(by: 1)

        model.delete()

        #expect(effect.disappeared.map(\.id) == [b])
        // 没按住 ⌘，卡片上没有 ⌘n。
        #expect(effect.disappeared.first?.shortcut == nil)
        #expect(effect.disappeared.first?.selected == true)
        // 条目已经删掉，后面的按键作用于新的列表；空位还占着 b 原来的地方。
        #expect(model.items.map(\.id) == [c, a])
        #expect(model.selectedID == a)
        #expect(model.cards.map(\.id) == [c, b, a])
        #expect(model.cards.map(\.index) == [0, nil, 1])

        effect.finishDisappear()

        #expect(model.cards.map(\.id) == [c, a])
    }

    @Test func gapsFromQuickDeletesKeepEveryCardInPlace() {
        let effect = FakeRemovalEffect()
        model.removalEffect = effect

        model.delete()
        model.delete()

        // 第二次删的 b 在屏幕上还在第二格。
        #expect(effect.disappeared.map(\.id) == [c, b])
        #expect(model.cards.map(\.id) == [c, b, a])

        // 先删的 c 散完了，还要等 b：右边的 a 一次补到最左边，不一格一格地挪。
        effect.finishDisappear(c)
        #expect(model.cards.map(\.id) == [c, b, a])
        effect.finishDisappear(b)
        #expect(model.cards.map(\.id) == [a])
    }

    @Test func otherGapsWaitUntilTheUndoneCardHasReappeared() {
        let effect = FakeRemovalEffect()
        model.removalEffect = effect
        model.delete()
        model.delete()
        effect.finishDisappear(c)

        model.undoDelete()

        // b 回到自己的空位上拼起来；c 的空位要等 b 拼好再去掉，否则 b 会在颗粒聚拢途中被挪走。
        #expect(model.cards.map(\.id) == [c, b, a])
        #expect(model.cards.map(\.isGap) == [true, false, false])

        effect.finishAppear()

        #expect(model.cards.map(\.id) == [b, a])
    }

    @Test func cardsOnlyMoveWithTheSlideAnimation() {
        let effect = FakeRemovalEffect()
        model.removalEffect = effect

        // 留了空位，其他卡片不动。
        model.delete()
        #expect(effect.slideCount == 0)

        effect.finishDisappear()
        #expect(effect.slideCount == 1)

        model.undoDelete()
        #expect(effect.slideCount == 2)
    }

    @Test func deletingWithoutEffectRemovesTheCardAtOnce() {
        let effect = FakeRemovalEffect()
        effect.playsDisappear = false
        model.removalEffect = effect

        model.delete()

        #expect(model.cards.map(\.id) == [b, a])
    }

    @Test func deletingPassesSearchTextAndWhetherTheCardWasSelected() {
        let effect = FakeRemovalEffect()
        model.removalEffect = effect
        model.query = "a"

        model.delete(model.items[0])

        #expect(effect.disappeared.first?.searchText == "a")
        #expect(effect.disappeared.first?.selected == true)
    }

    @Test func deletingFromContextMenuPassesWhetherTheCardWasSelected() {
        let effect = FakeRemovalEffect()
        model.removalEffect = effect

        model.delete(model.items[2])

        #expect(effect.disappeared.map(\.id) == [a])
        #expect(effect.disappeared.first?.selected == false)
    }

    @Test func searchingDropsGaps() {
        let effect = FakeRemovalEffect()
        model.removalEffect = effect
        model.delete()

        model.query = "a"

        #expect(model.cards.map(\.id) == [a])
    }

    @Test func undoneCardStaysHiddenUntilAppearEffectFinishes() {
        let effect = FakeRemovalEffect()
        model.removalEffect = effect
        model.moveSelection(by: 1)
        model.delete()

        model.undoDelete()

        #expect(model.items.map(\.id) == [c, b, a])
        #expect(model.selectedID == b)
        #expect(effect.appeared.map(\.id) == [b])
        #expect(effect.appeared.first?.shortcut == nil)
        #expect(model.hiddenIDs == [b])

        effect.finishAppear()

        #expect(model.hiddenIDs.isEmpty)
    }

    @Test func undoingBeforeTheCardIsGoneFillsItsOwnGap() {
        let effect = FakeRemovalEffect()
        model.removalEffect = effect
        model.moveSelection(by: 1)
        model.delete()

        model.undoDelete()

        #expect(model.cards.map(\.id) == [c, b, a])
        #expect(model.cards.allSatisfy { !$0.isGap })
        // 消失动画被出现动画取代，不会再来去掉空位。
        effect.finishDisappear()
        #expect(model.cards.map(\.id) == [c, b, a])
    }

    @Test func undoneCardShowsAtOnceWhenNoEffectPlays() {
        let effect = FakeRemovalEffect()
        effect.playsDisappear = false
        effect.playsAppear = false
        model.removalEffect = effect
        model.delete()

        model.undoDelete()

        #expect(model.items.map(\.id) == [c, b, a])
        #expect(model.hiddenIDs.isEmpty)
    }

    @Test func reopeningPanelStopsEffectsAndShowsHiddenCards() {
        let effect = FakeRemovalEffect()
        model.removalEffect = effect
        model.delete()
        model.undoDelete()

        model.didShow()

        #expect(effect.cancelCount >= 1)
        #expect(model.hiddenIDs.isEmpty)
        #expect(model.cards.allSatisfy { !$0.isGap })
    }
}
