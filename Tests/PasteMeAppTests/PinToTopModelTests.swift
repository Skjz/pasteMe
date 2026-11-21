import AppKit
import Testing
@testable import PasteMeApp
import PasteMeCore

/// 面板上的置顶（#77）：⌘P、卡片上的图钉按钮和右键菜单都走 `HistoryModel.setPinnedToTop`。
@MainActor
@Suite final class PinToTopModelTests {
    let store: ClipStore
    let model: HistoryModel
    /// 历史里从新到旧：c、b、a。
    let a, b, c: Int64
    let work: Pinboard
    var notices: [String] = []
    var editRequests: [PinboardEditRequest] = []

    init() throws {
        store = try ClipStore(path: ":memory:")
        a = try store.insert(ClipContent(kind: .text, text: "a"), source: nil, at: Date(timeIntervalSince1970: 1))
        b = try store.insert(ClipContent(kind: .text, text: "b"), source: nil, at: Date(timeIntervalSince1970: 2))
        c = try store.insert(ClipContent(kind: .text, text: "c"), source: nil, at: Date(timeIntervalSince1970: 3))
        work = try store.createPinboard(name: "工作", color: .blue)
        try store.pin(a, to: work.id)
        try store.pin(b, to: work.id)
        try store.setOrder([a, b], inPinboard: work.id)
        model = HistoryModel(store: store)
        model.onNotice = { [unowned self] message, _ in notices.append(message) }
        model.onEditPinboard = { [unowned self] in editRequests.append($0) }
        model.didShow()
    }

    var ids: [Int64] { model.items.map(\.id) }

    @Test func commandPTogglesTheSelectedEntryAndSelectionFollowsIt() throws {
        model.selectedID = a
        let reveals = model.revealSelectionCount

        model.togglePinToTop()
        #expect(ids == [a, c, b])
        #expect(model.selectedID == a)
        #expect(model.items.first?.pinnedToTopAt != nil)
        #expect(model.revealSelectionCount == reveals + 1)

        // 再复制新内容，它还在最前面。
        try store.insert(ClipContent(kind: .text, text: "d"), source: nil)
        model.reload()
        #expect(ids.first == a)

        model.togglePinToTop()
        #expect(ids.last == a)
        #expect(model.selectedID == a)
        #expect(model.revealSelectionCount == reveals + 2)
    }

    @Test func commandPNoLongerAsksForAPinboard() throws {
        try store.deletePinboard(work.id)
        model.didShow()

        model.togglePinToTop()

        #expect(editRequests.isEmpty)
        #expect(model.items.first?.pinnedToTopAt != nil)
        #expect(try store.pinboards().isEmpty)
    }

    @Test func pinningFromTheButtonDoesNotChangeTheSelection() {
        model.selectedID = c

        model.setPinnedToTop(true, model.items.last!)

        #expect(ids == [a, c, b])
        #expect(model.selectedID == c)
    }

    @Test func insideAPinboardTheOrderStaysAndANoticeSaysWhatHappened() {
        model.showTab(work.id)
        model.selectedID = b

        model.togglePinToTop()
        #expect(ids == [a, b])
        #expect(model.items.last?.pinnedToTopAt != nil)
        #expect(notices.last == "已置顶，在「历史」里排在最前面")

        model.togglePinToTop()
        #expect(model.items.last?.pinnedToTopAt == nil)
        #expect(notices.last == "已取消置顶")
    }

    @Test func inTheHistoryTheMoveIsTheFeedback() {
        model.togglePinToTop()
        #expect(notices.isEmpty)
    }

    /// 删除后马上改搜索词：空位已经清掉，颗粒还在播放。这时置顶要挪动卡片，也要先停掉颗粒。
    @Test func pinningAfterASearchStillStopsTheParticles() {
        let effect = FakeRemovalEffect()
        model.removalEffect = effect
        model.selectedID = c
        model.delete()
        model.query = "b"
        model.query = ""
        #expect(ids == [b, a])
        #expect(model.cards.allSatisfy { !$0.isGap })
        let cancels = effect.cancelCount

        model.setPinnedToTop(true, model.items[1])

        #expect(ids == [a, b])
        #expect(effect.cancelCount == cancels + 1)
    }

    /// 卡片没挪动时（Pinboard 里）鼠标还在它上面：图钉留着，也不请求滚动。
    @Test func pinningInPlaceKeepsTheHoverAndDoesNotScroll() {
        model.showTab(work.id)
        model.selectedID = b
        model.cardHovered(b, true)
        let reveals = model.revealSelectionCount

        model.togglePinToTop()

        #expect(model.showsPinButton(for: b))
        #expect(model.revealSelectionCount == reveals)
    }

    /// 置顶不改顺序时不停颗粒：停掉会让颗粒忘了哪些卡片还在补位的途中。
    @Test func pinningWithoutAMoveLeavesTheParticlesAlone() {
        let effect = FakeRemovalEffect()
        model.removalEffect = effect
        model.showTab(work.id)
        model.selectedID = a
        model.delete()
        effect.finishDisappear()
        let cancels = effect.cancelCount

        model.togglePinToTop()

        #expect(effect.cancelCount == cancels)
        #expect(effect.reorderCount == 0)
    }

    /// 取消置顶一条很旧的条目：它回到按时间的位置，落在默认读出的 200 条以外。选中项不变，列表里还有它。
    @Test func unpinningAnOldEntryKeepsItSelected() throws {
        let store = try ClipStore(path: ":memory:")
        let oldest = try store.insert(ClipContent(kind: .text, text: "oldest"), source: nil, at: Date(timeIntervalSince1970: 1))
        for i in 2...205 {
            try store.insert(ClipContent(kind: .text, text: "entry \(i)"), source: nil, at: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        try store.setPinnedToTop(true, id: oldest)
        let model = HistoryModel(store: store)
        model.didShow()
        #expect(model.items.first?.id == oldest)
        model.selectedID = oldest
        let reveals = model.revealSelectionCount

        model.togglePinToTop()

        #expect(model.selectedID == oldest)
        #expect(model.items.last?.id == oldest)
        #expect(model.revealSelectionCount == reveals + 1)
    }

    /// 搜索只命中一条很旧的置顶条目，取消置顶后它还在结果里：不放大读取条数，清空搜索后仍只读出 200 条。
    @Test func unpinningInASearchDoesNotGrowTheWholeHistory() throws {
        let store = try ClipStore(path: ":memory:")
        let needle = try store.insert(ClipContent(kind: .text, text: "needle"), source: nil, at: Date(timeIntervalSince1970: 1))
        for i in 2...305 {
            try store.insert(ClipContent(kind: .text, text: "entry \(i)"), source: nil, at: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        try store.setPinnedToTop(true, id: needle)
        let model = HistoryModel(store: store)
        model.didShow()
        model.query = "needle"
        #expect(model.items.map(\.id) == [needle])

        model.togglePinToTop()
        #expect(model.items.map(\.id) == [needle])
        #expect(model.selectedID == needle)

        model.clearSearch()
        #expect(model.items.count == 200)
    }

    /// 搜索时只给命中的置顶条目让出名额：200 条置顶都不命中时，搜索结果还是 200 条，不多读。
    @Test func pinnedEntriesFilteredOutOfASearchDoNotAddRows() throws {
        let store = try ClipStore(path: ":memory:")
        for i in 1...200 {
            let id = try store.insert(ClipContent(kind: .text, text: "pinned \(i)"), source: nil, at: Date(timeIntervalSince1970: TimeInterval(i)))
            try store.setPinnedToTop(true, id: id)
        }
        for i in 1...300 {
            try store.insert(ClipContent(kind: .text, text: "match \(i)"), source: nil, at: Date(timeIntervalSince1970: TimeInterval(1_000 + i)))
        }
        let model = HistoryModel(store: store)
        model.didShow()

        model.query = "match"

        #expect(model.items.count == 200)
    }

    /// 「在历史里查看」一条较早的普通条目：读到它后面再多 100 条为止，名次里排在前面的置顶条目不再多算一次。
    @Test func showingAnOldEntryInHistoryReadsUpToItPlusAMargin() throws {
        let store = try ClipStore(path: ":memory:")
        for i in 1...50 {
            let id = try store.insert(ClipContent(kind: .text, text: "pinned \(i)"), source: nil, at: Date(timeIntervalSince1970: TimeInterval(10_000 + i)))
            try store.setPinnedToTop(true, id: id)
        }
        var target: Int64 = 0
        for i in 1...600 {
            let id = try store.insert(ClipContent(kind: .text, text: "entry \(i)"), source: nil, at: Date(timeIntervalSince1970: TimeInterval(i)))
            if i == 300 { target = id }
        }
        let position = try #require(try store.historyPosition(of: target))
        #expect(position == 50 + 300)
        let model = HistoryModel(store: store)
        model.didShow()
        model.query = "entry 300"

        model.showInHistory(model.items.first { $0.id == target })

        #expect(model.items.count == position + 100)
        #expect(model.selectedID == target)
    }

    /// 搜索时为了留住选中项放大的读取条数，清空搜索后不再沿用。
    @Test func clearingTheSearchDropsTheGrownLimit() throws {
        let store = try ClipStore(path: ":memory:")
        let oldest = try store.insert(ClipContent(kind: .text, text: "entry 1"), source: nil, at: Date(timeIntervalSince1970: 1))
        for i in 2...300 {
            try store.insert(ClipContent(kind: .text, text: "entry \(i)"), source: nil, at: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        try store.setPinnedToTop(true, id: oldest)
        let model = HistoryModel(store: store)
        model.didShow()
        model.query = "entry"
        model.selectedID = oldest

        model.togglePinToTop()
        #expect(model.selectedID == oldest)
        #expect(model.items.contains { $0.id == oldest })

        model.clearSearch()
        #expect(model.items.count == 200)
    }

    /// 置顶的条目不占「历史」的 200 条名额：置顶满 200 条后，新复制的内容照样出现在列表里。
    @Test func pinnedEntriesDoNotCrowdOutNewCopies() throws {
        let store = try ClipStore(path: ":memory:")
        for i in 1...200 {
            let id = try store.insert(ClipContent(kind: .text, text: "pinned \(i)"), source: nil, at: Date(timeIntervalSince1970: TimeInterval(i)))
            try store.setPinnedToTop(true, id: id, at: Date(timeIntervalSince1970: TimeInterval(1_000 + i)))
        }
        let fresh = try store.insert(ClipContent(kind: .text, text: "fresh"), source: nil, at: Date(timeIntervalSince1970: 500))
        let model = HistoryModel(store: store)

        model.didShow()

        #expect(model.items.count == 201)
        #expect(model.items.last?.id == fresh)
    }

    /// Pinboard 里置顶不改顺序：不播换位动画，紧接着的删除照常播颗粒。
    @Test func insideAPinboardPinningDoesNotStartAReorder() {
        let effect = FakeRemovalEffect()
        model.removalEffect = effect
        model.showTab(work.id)
        model.selectedID = b

        model.togglePinToTop()
        #expect(effect.reorderCount == 0)

        model.showTab(nil)
        model.selectedID = b
        model.togglePinToTop()
        #expect(effect.reorderCount == 1)
    }

    /// 删除后的空位和列表用同一套规则：置顶时间是多少（哪怕早于 `Date.distantPast`）都排在没置顶的前面。
    @Test func aGapForAPinnedCardStaysFirstForAnyPinTime() throws {
        try store.setPinnedToTop(true, id: a, at: Date.distantPast.addingTimeInterval(-1))
        model.reload()
        #expect(ids == [a, c, b])
        let effect = FakeRemovalEffect()
        model.removalEffect = effect
        model.selectedID = a

        model.delete()

        #expect(model.cards.map(\.id) == [a, c, b])
        #expect(model.cards.first?.isGap == true)
    }

    @Test func aDeletedPinnedCardLeavesItsGapAtTheFront() {
        model.selectedID = a
        model.togglePinToTop()
        let effect = FakeRemovalEffect()
        model.removalEffect = effect

        model.delete()

        #expect(ids == [c, b])
        #expect(model.cards.map(\.id) == [a, c, b])
        #expect(model.cards.map(\.isGap) == [true, false, false])

        effect.finishDisappear()
        model.undoDelete()
        effect.finishAppear()
        #expect(ids == [a, c, b])
        #expect(model.items.first?.pinnedToTopAt != nil)
    }
}
