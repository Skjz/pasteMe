import Foundation
import Testing
@testable import PasteMeApp
import PasteMeCore

/// 在卡片标题栏里起标题、改标题（#33）。
@MainActor
@Suite final class CardTitleTests {
    let store: ClipStore
    let model: HistoryModel
    /// 历史里从新到旧：b、a。a 有标题「旧标题」。
    let b, a: Int64
    var previewClosed = 0

    init() throws {
        store = try ClipStore(path: ":memory:")
        a = try store.insert(ClipContent(kind: .text, text: "a"), source: nil, at: Date(timeIntervalSince1970: 1))
        b = try store.insert(ClipContent(kind: .link, text: "https://example.com"), source: nil, at: Date(timeIntervalSince1970: 2))
        try store.setTitle("旧标题", id: a)
        model = HistoryModel(store: store)
        model.onWillEditTitle = { [unowned self] in previewClosed += 1 }
        model.didShow()
    }

    private func title(of id: Int64) -> String? {
        model.items.first { $0.id == id }?.title
    }

    @Test func renamingSelectsTheCardAndPutsTheOldTitleInTheField() throws {
        model.rename(try #require(model.items.first { $0.id == a }))
        #expect(model.selectedID == a)
        #expect(model.titleEditingID == a)
        #expect(model.titleDraft == "旧标题")
        #expect(model.focus == .title)
        #expect(previewClosed == 1)

        model.cancelTitle()
        model.rename()
        #expect(model.titleEditingID == a)
        #expect(model.titleDraft == "旧标题")
    }

    @Test func returnSavesTheTitleAndFocusGoesBackToTheCards() {
        model.rename()
        model.titleDraft = "  新标题  "
        model.commitTitle()
        // 选中的是最新的 b，a 不变。
        #expect(title(of: b) == "新标题")
        #expect(title(of: a) == "旧标题")
        #expect(model.titleEditingID == nil)
        #expect(model.focus == .cards)
    }

    @Test func clearingTheFieldRemovesTheTitle() throws {
        model.rename(try #require(model.items.first { $0.id == a }))
        model.titleDraft = " "
        model.commitTitle()
        #expect(title(of: a) == nil)
    }

    @Test func escapeKeepsTheOldTitle() throws {
        model.rename(try #require(model.items.first { $0.id == a }))
        model.titleDraft = "不要了"
        model.cancelTitle()
        #expect(title(of: a) == "旧标题")
        #expect(model.titleEditingID == nil)
        #expect(model.focus == .cards)
    }

    @Test func movingFocusElsewhereSaves() {
        model.rename()
        model.titleDraft = "点进搜索框"
        model.focus = .search
        #expect(title(of: b) == "点进搜索框")
        #expect(model.titleEditingID == nil)
        #expect(model.focus == .search)

        model.rename()
        model.titleDraft = "点了别的卡片"
        model.selectedID = a
        model.focus = .cards
        #expect(title(of: b) == "点了别的卡片")
    }

    @Test func switchingTabsOrFilteringTheCardAwaySaves() throws {
        let pinboard = try store.createPinboard(name: "工作", color: .blue)
        model.reloadPinboards()
        model.rename()
        model.titleDraft = "切换标签"
        model.showTab(pinboard.id)
        #expect(model.titleEditingID == nil)
        #expect(try store.item(id: b)?.title == "切换标签")

        model.showTab(nil)
        model.rename()
        model.titleDraft = "被筛选掉"
        model.toggleKind(.text)
        #expect(model.titleEditingID == nil)
        #expect(try store.item(id: b)?.title == "被筛选掉")
    }

    @Test func renamingAnotherCardSavesTheFirst() throws {
        model.rename()
        model.titleDraft = "第一张"
        model.rename(try #require(model.items.first { $0.id == a }))
        #expect(title(of: b) == "第一张")
        #expect(model.titleEditingID == a)
        #expect(model.titleDraft == "旧标题")
    }

    @Test func draggingInsideTheFieldDoesNotDragTheCard() throws {
        var dragged: [Int64] = []
        model.onBeginDrag = { dragged.append($0.id) }
        model.rename()
        model.beginDrag(try #require(model.items.first { $0.id == b }))
        model.beginDrag(try #require(model.items.first { $0.id == a }))
        #expect(dragged == [a])
    }

    @Test func reopeningThePanelEndsEditing() {
        model.rename()
        model.didShow()
        #expect(model.titleEditingID == nil)
        #expect(model.focus == .cards)
    }
}
