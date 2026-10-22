import Foundation
import Testing
@testable import PasteMeApp
import PasteMeCore

/// 按住 ⌘ 时才显示 ⌘1…⌘9，编号从第一张完整显示的卡片数起（#39）。
@MainActor
@Suite final class ShortcutHintTests {
    let store: ClipStore
    let model: HistoryModel
    /// 历史里从新到旧的 12 条，`ids[0]` 最新。
    let ids: [Int64]
    var pasted: [Int64] = []
    /// `schedule` 推迟执行的动作，测试自己决定什么时候执行。
    var scheduled: [(delay: TimeInterval, action: @MainActor () -> Void)] = []

    init() throws {
        store = try ClipStore(path: ":memory:")
        var ids: [Int64] = []
        for i in 0..<12 {
            ids.insert(try store.insert(ClipContent(kind: .text, text: "条目 \(i)"), source: nil, at: Date(timeIntervalSince1970: Double(i))), at: 0)
        }
        self.ids = ids
        model = HistoryModel(store: store)
        model.onPaste = { [unowned self] item, _ in pasted.append(item.id) }
        model.schedule = { [unowned self] delay, action in scheduled.append((delay, action)) }
        model.didShow()
    }

    /// 时间到了：执行所有推迟的动作。
    private func elapse() {
        let actions = scheduled
        scheduled = []
        actions.forEach { $0.action() }
    }

    private func holdCommand() {
        model.shortcutKeysChanged(held: true)
        elapse()
    }

    // MARK: 什么时候显示

    @Test func hintsAppearOnlyAfterHoldingCommandForAMoment() {
        #expect(!model.showsShortcutHints)
        model.shortcutKeysChanged(held: true)
        #expect(!model.showsShortcutHints)
        #expect(scheduled.map(\.delay) == [HistoryModel.shortcutHintDelay])

        elapse()
        #expect(model.showsShortcutHints)

        model.shortcutKeysChanged(held: false)
        #expect(!model.showsShortcutHints)
    }

    @Test func aQuickCommandShortcutDoesNotFlashTheHints() {
        model.shortcutKeysChanged(held: true)
        model.shortcutKeysChanged(held: false)
        elapse()
        #expect(!model.showsShortcutHints)

        // 松开又按下：第一次的等待作废，从第二次按下时重新算。
        model.shortcutKeysChanged(held: true)
        model.shortcutKeysChanged(held: false)
        model.shortcutKeysChanged(held: true)
        let actions = scheduled
        actions[0].action()
        #expect(!model.showsShortcutHints)
        actions[1].action()
        #expect(model.showsShortcutHints)
    }

    @Test func addingShiftKeepsTheHints() {
        holdCommand()
        // ⌘ 换成 ⇧⌘ 还是按着，不重新等待。
        model.shortcutKeysChanged(held: true)
        #expect(scheduled.isEmpty)
        #expect(model.showsShortcutHints)
    }

    @Test func hintsHideWhileEditingATitle() {
        holdCommand()
        model.rename()
        #expect(!model.showsShortcutHints)
        model.commitTitle()
        #expect(model.showsShortcutHints)
    }

    @Test func reopeningThePanelStartsWithoutHints() {
        holdCommand()
        model.firstVisibleCard = 4
        model.panelWillHide()
        // 已经显示的提示跟着面板滑出去，不在收起动画里重画卡片。
        #expect(model.showsShortcutHints)

        model.didShow()
        #expect(!model.showsShortcutHints)
        #expect(model.firstVisibleCard == 0)
    }

    @Test func hidingThePanelCancelsTheWait() {
        model.shortcutKeysChanged(held: true)
        model.panelWillHide()
        elapse()
        #expect(!model.showsShortcutHints)
    }

    // MARK: 从哪一张数起

    @Test func commandDigitsCountFromTheFirstFullyVisibleCard() {
        model.paste(at: 0)
        model.firstVisibleCard = 3
        model.paste(at: 0)
        model.paste(at: 8)
        #expect(pasted == [ids[0], ids[3], ids[11]])

        // 后面不够 9 张时，多出来的 ⌘数字 什么都不做。
        model.firstVisibleCard = 5
        model.paste(at: 7)
        #expect(pasted.count == 3)
    }

    @Test func numbersCoverNineCardsFromTheFirstOne() {
        #expect(HistoryModel.shortcutNumber(forItemAt: 3, first: 3) == 1)
        #expect(HistoryModel.shortcutNumber(forItemAt: 11, first: 3) == 9)
        #expect(HistoryModel.shortcutNumber(forItemAt: 12, first: 3) == nil)
        #expect(HistoryModel.shortcutNumber(forItemAt: 2, first: 3) == nil)
        // 不显示提示，或者是空位。
        #expect(HistoryModel.shortcutNumber(forItemAt: 3, first: nil) == nil)
        #expect(HistoryModel.shortcutNumber(forItemAt: nil, first: 3) == nil)
    }

    @Test func gapsBeforeTheFirstCardAreSkipped() {
        let effect = FakeRemovalEffect()
        model.removalEffect = effect
        model.moveSelection(by: 1)
        model.delete()
        // 第 2 格是空位，最左边完整显示的是它：⌘1 是空位右边的那张。
        #expect(model.cards[1].isGap)
        model.firstVisibleCard = 1
        #expect(model.firstShortcutIndex == 1)
        model.paste(at: 0)
        #expect(pasted == [ids[2]])
    }

    @Test func deleteAndUndoDrawTheNumberTheCardShows() {
        let effect = FakeRemovalEffect()
        model.removalEffect = effect
        model.firstVisibleCard = 2
        model.moveSelection(by: 4)
        model.delete()
        #expect(effect.disappeared.last?.shortcut == nil)
        model.undoDelete()
        #expect(effect.appeared.last?.shortcut == nil)
        effect.finishAppear()

        holdCommand()
        model.delete()
        #expect(effect.disappeared.last?.shortcut == 3)
        model.undoDelete()
        #expect(effect.appeared.last?.shortcut == 3)
    }

    // MARK: 滚动位置

    @Test func firstFullyVisibleCardFollowsTheScrollPosition() {
        let pitch = ClipCardView.size.width + HistoryView.cardSpacing
        // 没有滚动时，卡片列表左边留着 30 点。
        #expect(HistoryView.firstFullyVisibleCard(contentMinX: 30) == 0)
        #expect(HistoryView.firstFullyVisibleCard(contentMinX: 0) == 0)
        // 第 1 张露出了一部分：从第 2 张数起。
        #expect(HistoryView.firstFullyVisibleCard(contentMinX: -1) == 1)
        // 第 4 张正好贴着左边，或者因为小数差了不到半个点。
        #expect(HistoryView.firstFullyVisibleCard(contentMinX: -3 * pitch) == 3)
        #expect(HistoryView.firstFullyVisibleCard(contentMinX: -3 * pitch - 0.3) == 3)
        #expect(HistoryView.firstFullyVisibleCard(contentMinX: -3 * pitch - 2) == 4)
    }
}
