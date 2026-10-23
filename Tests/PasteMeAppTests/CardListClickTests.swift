import Foundation
import Testing
@testable import PasteMeApp

/// 预览开着时点卡片列表的空白处关掉预览：哪些地方算空白。
@Suite struct CardListClickTests {
    /// 两张卡片，230×240，间距 18，从 (40, 60) 开始（坐标原点在左上）。
    let cards = [
        CGRect(x: 40, y: 60, width: 230, height: 240),
        CGRect(x: 288, y: 60, width: 230, height: 240),
    ]

    @Test func onACardIsNotBlank() {
        #expect(!CardListClick.isBlank(CGPoint(x: 100, y: 150), cardFrames: cards, selected: nil))
        // 选中的卡片放大了 5%，放大出来的边也算卡片。
        #expect(!CardListClick.isBlank(CGPoint(x: 36, y: 150), cardFrames: cards, selected: cards[0]))
    }

    @Test func betweenAndAfterTheCardsIsBlank() {
        // 两张卡片之间的空隙正中。
        #expect(CardListClick.isBlank(CGPoint(x: 279, y: 150), cardFrames: cards, selected: cards[0]))
        // 没选中的卡片不放大：贴着它左边 2 点也算空隙（在真实应用里点过，全按放大算时空隙只剩 6 点宽，很难点中）。
        #expect(CardListClick.isBlank(CGPoint(x: 286, y: 150), cardFrames: cards, selected: cards[0]))
        // 最后一张右边。
        #expect(CardListClick.isBlank(CGPoint(x: 900, y: 150), cardFrames: cards, selected: cards[0]))
        // 卡片下面的留白。
        #expect(CardListClick.isBlank(CGPoint(x: 900, y: 305), cardFrames: cards, selected: nil))
    }

    @Test func aboveTheCardsIsNotTheCardList() {
        // 搜索栏那一行：不算卡片列表的空白，点了不关预览。
        #expect(!CardListClick.isBlank(CGPoint(x: 900, y: 20), cardFrames: cards, selected: nil))
        #expect(!CardListClick.isBlank(CGPoint(x: 100, y: 150), cardFrames: [], selected: nil))
    }
}
