import Foundation
import SwiftUI
import Testing
@testable import PasteMeApp
import PasteMeCore

/// SwiftUI 进入 `withAnimation` 前会先把之前的改动渲染出来（`SwiftUIAssumptionTests` 验证这一点）。
/// 所以删除、撤销做到一半时视图就可能看到 `cards`。这里把 `HistoryModel.animate` 换成先检查当时的 `cards`、
/// 再执行动画代码，确认视图看到的中间状态没有问题：
/// - 同一个条目不会出现两次；
/// - 留空位的删除、回到自己空位的撤销过程中，没有任何卡片换位置。
@MainActor
@Suite final class PanelFlushTests {
    let store: ClipStore
    let model: HistoryModel
    let effect = FakeRemovalEffect()
    /// 每次进入 `animate` 时视图会看到的卡片：id 和是否是空位。
    var flushes: [[PanelCard]] = []

    init() throws {
        store = try ClipStore(path: ":memory:")
        for i in 0..<6 {
            try store.insert(ClipContent(kind: .text, text: "item \(i)"), source: nil, at: Date(timeIntervalSince1970: Double(i)))
        }
        model = HistoryModel(store: store)
        model.removalEffect = effect
        model.didShow()
        model.animate = { [unowned self] animation, body in
            flushes.append(model.cards)
            withAnimation(animation, body)
        }
    }

    /// 执行 `operation`，检查期间每一次提前渲染。`keepsPositions` 为 true 时，任何卡片都不应换位置。
    func expectCleanFlushes(keepsPositions: Bool, _ operation: () -> Void, sourceLocation: SourceLocation = #_sourceLocation) {
        let before = model.cards
        flushes = []
        operation()
        #expect(!flushes.isEmpty, "操作没有经过 animate", sourceLocation: sourceLocation)
        for cards in flushes + [model.cards] {
            let ids = cards.map(\.id)
            #expect(Set(ids).count == ids.count, "同一个条目出现了两次：\(ids)", sourceLocation: sourceLocation)
            if keepsPositions {
                let positions = Dictionary(uniqueKeysWithValues: before.enumerated().map { ($1.id, $0) })
                for (position, card) in cards.enumerated() {
                    if let old = positions[card.id] {
                        #expect(old == position, "卡片 \(card.id) 从第 \(old) 格挪到了第 \(position) 格", sourceLocation: sourceLocation)
                    }
                }
            }
        }
    }

    @Test func deletingSeveralCardsInARowNeverShowsAHalfDoneList() {
        for _ in 0..<3 {
            expectCleanFlushes(keepsPositions: true) { model.delete() }
        }
    }

    @Test func deletingFromTheContextMenuNeverShowsAHalfDoneList() {
        expectCleanFlushes(keepsPositions: true) { model.delete(model.items[3]) }
        expectCleanFlushes(keepsPositions: true) { model.delete(model.items[1]) }
    }

    @Test func undoingIntoItsOwnGapNeverShowsAHalfDoneList() {
        model.delete()
        model.delete()
        expectCleanFlushes(keepsPositions: true) { model.undoDelete() }
        expectCleanFlushes(keepsPositions: true) { model.undoDelete() }
    }

    @Test func closingGapsAndUndoingAfterwardsNeverShowDuplicates() {
        model.delete()
        model.delete()
        expectCleanFlushes(keepsPositions: false) { effect.finishDisappear() }
        expectCleanFlushes(keepsPositions: false) { model.undoDelete() }
        expectCleanFlushes(keepsPositions: false) { model.undoDelete() }
    }
}
