import AppKit
import Testing
@testable import PasteMeApp
import PasteMeCore

/// 面板上的 Pinboard：标签、固定、⌘P、拿掉和撤销、拖动排序、拖到标签上、在历史里查看、按 Pinboard 筛选（#9）。
@MainActor
@Suite final class PinboardModelTests {
    let suiteName = "PasteMeTests.PinboardModel.\(UUID().uuidString)"
    let settings: PasteMeCore.Settings
    let store: ClipStore
    let model: HistoryModel
    /// 历史里从新到旧：c、b、a。
    let a, b, c: Int64
    let work, code: Pinboard
    var notices: [String] = []
    var editRequests: [PinboardEditRequest] = []

    init() throws {
        settings = PasteMeCore.Settings(defaults: try #require(UserDefaults(suiteName: suiteName)))
        store = try ClipStore(path: ":memory:")
        a = try store.insert(ClipContent(kind: .text, text: "a"), source: nil, at: Date(timeIntervalSince1970: 1))
        b = try store.insert(ClipContent(kind: .text, text: "b"), source: nil, at: Date(timeIntervalSince1970: 2))
        c = try store.insert(ClipContent(kind: .text, text: "c"), source: nil, at: Date(timeIntervalSince1970: 3))
        work = try store.createPinboard(name: "工作", color: .blue)
        code = try store.createPinboard(name: "代码", color: .green)
        try store.pin(a, to: work.id)
        try store.pin(b, to: work.id)
        try store.setOrder([a, b], inPinboard: work.id)
        model = HistoryModel(store: store, settings: settings)
        model.onNotice = { [unowned self] message, _ in notices.append(message) }
        model.onEditPinboard = { [unowned self] in editRequests.append($0) }
        model.didShow()
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    var ids: [Int64] { model.items.map(\.id) }

    @Test func tabsShowHistoryThenEachPinboardInItsOwnOrder() {
        #expect(model.pinboards == [work, code])
        #expect(model.pinboardID == nil && ids == [c, b, a])

        model.showTab(work.id)
        #expect(ids == [a, b])
        #expect(model.selectedID == a)

        model.showTab(code.id)
        #expect(ids.isEmpty)
    }

    @Test func cyclingWrapsAroundAndReopeningStartsAtHistory() {
        model.cycleTab(by: 1)
        #expect(model.pinboardID == work.id)
        model.cycleTab(by: 1)
        model.cycleTab(by: 1)
        #expect(model.pinboardID == nil)
        model.cycleTab(by: -1)
        #expect(model.pinboardID == code.id)

        model.didShow()
        #expect(model.pinboardID == nil)
    }

    @Test func searchingInsideAPinboardOnlyFindsItsEntries() {
        model.showTab(work.id)
        model.query = "c"
        #expect(ids.isEmpty)
        model.query = "b"
        #expect(ids == [b])
    }

    @Test func commandPPinsToTheLastUsedPinboardAndRemembersIt() throws {
        model.selectedID = c
        model.pin(to: code)
        #expect(notices.last == "已固定到「代码」")
        #expect(settings.lastPinboardID == code.id)

        model.selectedID = a
        model.pinToRecentPinboard()
        #expect(try store.items(matching: ClipQuery(pinboardID: code.id)).map(\.id) == [a, c])

        model.pinToRecentPinboard()
        #expect(notices.last == "已经在「代码」里了")
        // 重启后还记得。
        #expect(HistoryModel(store: store, settings: settings).pinboardID == nil)
        #expect(settings.lastPinboardID == code.id)
    }

    @Test func commandPWithoutPinboardsAsksForANewOne() throws {
        try store.deletePinboard(work.id)
        try store.deletePinboard(code.id)
        model.didShow()

        model.pinToRecentPinboard()

        #expect(editRequests == [.create(pinning: model.items.first)])
    }

    @Test func creatingAPinboardCanPinTheEntryRightAway() throws {
        let item = try #require(model.items.first)
        let created = try #require(model.createPinboard(named: "  稍后看 ", color: .pink, pinning: item))

        #expect(model.pinboards.map(\.name) == ["工作", "代码", "稍后看"])
        #expect(try store.items(matching: ClipQuery(pinboardID: created.id)).map(\.id) == [item.id])
        #expect(model.createPinboard(named: " ", color: .red) == nil)
    }

    @Test func deletingInsideAPinboardOnlyUnpinsAndCanBeUndone() throws {
        model.showTab(work.id)
        model.delete()

        #expect(ids == [b])
        #expect(try store.count() == 3)
        model.undoDelete()
        #expect(ids == [a, b])
        #expect(model.selectedID == a)
    }

    @Test func switchingTabsForgetsWhatCanBeUndone() {
        model.delete()
        #expect(model.canUndoDelete)
        model.showTab(work.id)
        #expect(!model.canUndoDelete)
    }

    @Test func untickingAPinboardInTheMenuUnpins() throws {
        let item = try #require(model.items.first { $0.id == b })
        model.setPinned(false, item, in: work)
        #expect(try store.items(matching: ClipQuery(pinboardID: work.id)).map(\.id) == [a])
        #expect(model.items.first { $0.id == b }?.pinboardIDs.isEmpty == true)
    }

    @Test func draggingACardOverAnotherReordersAndIsSavedWhenTheDragEnds() throws {
        model.showTab(work.id)
        #expect(model.canReorder)
        model.draggingID = b
        let first = try #require(model.items.first)

        model.moveDraggedCard(to: first)
        #expect(ids == [b, a])
        model.endDrag()

        #expect(try store.items(matching: ClipQuery(pinboardID: work.id)).map(\.id) == [b, a])
        #expect(model.draggingID == nil)
    }

    @Test func reorderingNeedsTheWholePinboard() {
        #expect(!model.canReorder)
        model.showTab(work.id)
        model.query = "a"
        #expect(!model.canReorder)
    }

    @Test func droppingACardOnATabPinsIt() throws {
        model.draggingID = c
        #expect(model.dropDraggedCard(on: code))
        #expect(try store.items(matching: ClipQuery(pinboardID: code.id)).map(\.id) == [c])

        model.draggingID = nil
        #expect(!model.dropDraggedCard(on: code))
    }

    @Test func deletingThePinboardBeingViewedGoesBackToHistory() {
        model.showTab(work.id)
        model.deletePinboard(work)

        #expect(model.pinboardID == nil)
        #expect(model.pinboards == [code])
        #expect(ids == [c, b, a])
    }

    @Test func renamingAndRecoloringUpdateTheTabs() {
        model.renamePinboard(work, to: "项目", color: .red)
        model.setColor(.teal, of: code)
        #expect(model.pinboards.map(\.name) == ["项目", "代码"])
        #expect(model.pinboards.map(\.color) == [.red, .teal])
    }

    @Test func showInHistoryClearsTheSearchAndSelectsTheEntry() throws {
        model.showTab(work.id)
        #expect(model.canShowInHistory)
        model.query = "a"
        model.showInHistory()

        #expect(model.pinboardID == nil && model.query.isEmpty)
        #expect(ids == [c, b, a])
        #expect(model.selectedID == a)
    }

    @Test func showInHistoryReachesEntriesOlderThanTheFirstPage() throws {
        let old = try store.insert(ClipContent(kind: .text, text: "很早以前"), source: nil, at: Date(timeIntervalSince1970: 0))
        for i in 0..<250 {
            try store.insert(ClipContent(kind: .text, text: "新 \(i)"), source: nil, at: Date(timeIntervalSince1970: 10 + Double(i)))
        }
        model.didShow()
        #expect(!ids.contains(old))

        model.query = "很早"
        model.showInHistory()

        #expect(ids.contains(old))
        #expect(model.selectedID == old)
        // 下次呼出面板又只读第一页。
        model.didShow()
        #expect(ids.count == 200)
    }

    @Test func atListsPinboardsAndFiltersByThem() {
        model.focus = .search
        model.query = "@工"
        #expect(model.suggestions == [.pinboard(work)])

        model.acceptSuggestion()
        #expect(model.filters.pinboardIDs == [work.id])
        #expect(ids == [b, a])
        #expect(model.activeConditions == ["固定在「工作」里"])
    }

    @Test func pinboardFilterIsDroppedWhenThePinboardIsDeleted() {
        model.filters.pinboardIDs = [work.id]
        model.deletePinboard(work)
        #expect(model.filters.pinboardIDs.isEmpty)
        #expect(ids == [c, b, a])
    }
}

/// 预览和编辑：空格、⌘E、改标题、⌘N 新建（#10）。
@MainActor
@Suite final class PreviewModelTests {
    let store: ClipStore
    let model: HistoryModel
    var requests: [PreviewRequest] = []
    var edited: [Int64] = []

    init() throws {
        store = try ClipStore(path: ":memory:")
        try store.insert(ClipContent(kind: .text, text: "hello"), source: nil, at: Date(timeIntervalSince1970: 1))
        try store.insert(ClipContent(kind: .image, image: try #require(PanelTestImage.png)), source: nil, at: Date(timeIntervalSince1970: 2))
        model = HistoryModel(store: store) { Date(timeIntervalSince1970: 100) }
        model.onPreview = { [unowned self] in requests.append($0) }
        model.onEdited = { [unowned self] in edited.append($0) }
        model.didShow()
    }

    var text: ClipItem { model.items.first { $0.kind == .text }! }
    var image: ClipItem { model.items.first { $0.kind == .image }! }

    @Test func previewEditAndNewTextAskForTheRightWindow() {
        model.preview()
        model.edit(text)
        model.edit(image)
        // 起标题在卡片的标题栏里做，不打开预览（#33）。
        model.rename(image)
        model.newText()

        #expect(requests == [.show(image), .edit(text), .newText])
    }

    @Test func savedEditsShowUpOnTheCard() throws {
        let id = text.id
        model.saveEdits(of: id, text: "hello, world", rtf: nil, title: "问候")

        let item = try #require(model.items.first { $0.id == id })
        #expect(item.preview == "hello, world" && item.title == "问候")
        #expect(edited == [id])
        model.query = "问候"
        #expect(model.items.map(\.id) == [id])
    }

    @Test func savingOnlyTheTitleLeavesTheTextAlone() throws {
        let id = text.id
        model.saveEdits(of: id, text: nil, rtf: nil, title: "标题")
        #expect(try store.content(id: id)?.text == "hello")
        #expect(edited.isEmpty)
    }

    @Test func newTextGoesFirstAndIsSelected() throws {
        model.addText("新的一条", rtf: nil, title: nil)
        #expect(model.items.first?.preview == "新的一条")
        #expect(model.selectedID == model.items.first?.id)

        model.addText("  ", rtf: nil, title: "空的")
        #expect(model.items.count == 3)
    }

    @Test func newTextInsideAPinboardIsPinnedThere() throws {
        let board = try store.createPinboard(name: "模板", color: .purple)
        model.reloadPinboards()
        model.showTab(board.id)

        model.addText("签名", rtf: nil, title: "邮件签名")

        #expect(model.items.map(\.title) == ["邮件签名"])
    }
}

enum PanelTestImage {
    static var png: Data? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
        return rep?.representation(using: .png, properties: [:])
    }
}
