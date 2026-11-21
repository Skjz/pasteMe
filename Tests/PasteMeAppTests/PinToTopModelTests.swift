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
        let cancels = effect.cancelCount

        model.setPinnedToTop(true, model.items[0])

        #expect(effect.cancelCount == cancels + 1)
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
