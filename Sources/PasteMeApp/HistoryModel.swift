import Foundation
import Observation
import PasteMeCore

/// 面板上用按钮和菜单选的筛选条件。搜索框里写的 `type:`、`app:` 不在这里，见 `ClipQuery.parse`。
struct PanelFilters: Equatable {
    /// 空集合表示不限类型。
    var kinds: Set<ClipKind> = []
    var sourceApp: SourceApp?
    var timeRange = TimeRange.all

    var isActive: Bool { !kinds.isEmpty || sourceApp != nil || timeRange != .all }
}

/// 历史面板的状态：当前搜索词和筛选条件、列表、选中项、焦点，以及可以撤销的删除。
@Observable
@MainActor
final class HistoryModel {
    /// 搜索框里的文字。修改后立即重新查询。
    var query = "" {
        didSet { if query != oldValue { reloadUnlessResetting() } }
    }
    /// 修改后立即重新查询。面板每次呼出时清空，和搜索词一样。
    var filters = PanelFilters() {
        didSet { if filters != oldValue { reloadUnlessResetting() } }
    }
    var selectedID: Int64?
    private(set) var items: [ClipItem] = []
    /// 光标的样式。初始值和修改都来自 `Settings.cursorStyle`，放在这里是为了让视图随之更新。
    var cursorStyle = CursorStyle.breathe
    /// 面板在屏幕上（包括呼出和收起动画期间）。为 false 时视图停掉一直在跑的动画。
    var isPanelVisible = false
    /// 键盘操作当前作用于搜索框还是卡片列表，视图据此移动键盘焦点。
    var focus: PanelFocus = .search
    /// 每次面板弹出时加一，视图据此把焦点放回搜索框、重新播放卡片出现的动画。
    private(set) var showCount = 0

    /// 粘贴某个条目。
    @ObservationIgnored var onPaste: (ClipItem, PasteMode) -> Void = { _, _ in }

    @ObservationIgnored private let store: ClipStore
    @ObservationIgnored private let now: () -> Date
    /// `didShow` 一次改好搜索词和筛选条件，最后只查询一次。
    @ObservationIgnored private var resetting = false
    /// 本次打开面板后删除的条目，最后删除的在末尾。面板重新打开时清空。
    private var deleted: [DeletedClip] = []

    var canUndoDelete: Bool { !deleted.isEmpty }

    /// `now` 用于测试时控制“今天”是哪一天。
    init(store: ClipStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    /// 没有搜索词，也没有筛选条件。
    var searchIsEmpty: Bool { query.isEmpty && !filters.isActive }

    /// 搜索框里的文字和面板上的筛选条件合起来的查询条件。
    var currentQuery: ClipQuery {
        var query = ClipQuery.parse(query)
        if !filters.kinds.isEmpty {
            query = query.restricting(to: filters.kinds)
        }
        query.sourceBundleID = filters.sourceApp?.bundleID
        (query.createdFrom, query.createdBefore) = filters.timeRange.bounds(now: now())
        return query
    }

    /// 当前起作用的条件，例如 ["类型为图片", "来自微信"]，没有结果时用来说明原因。
    var activeConditions: [String] {
        let query = currentQuery
        var conditions: [String] = []
        if let kinds = query.kinds {
            let names = ClipKind.allCases.filter(kinds.contains).map(\.title)
            conditions.append(names.isEmpty ? "类型条件没有交集" : "类型为" + names.joined(separator: "或"))
        }
        if let app = filters.sourceApp {
            conditions.append("来自\(app.name)")
        }
        if let name = query.sourceName {
            conditions.append("来源应用名包含“\(name)”")
        }
        if filters.timeRange != .all {
            conditions.append(filters.timeRange.title)
        }
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            conditions.append("包含“\(text)”")
        }
        return conditions
    }

    /// 清空搜索词和所有筛选条件。
    func clearSearch() {
        resetting = true
        query = ""
        filters = PanelFilters()
        resetting = false
        reload()
    }

    func toggleKind(_ kind: ClipKind) {
        if filters.kinds.contains(kind) {
            filters.kinds.remove(kind)
        } else {
            filters.kinds.insert(kind)
        }
    }

    /// 历史里出现过的来源应用，按条目数排列。打开应用筛选菜单时才查询。
    func sourceApps() -> [SourceApp] {
        do {
            return try store.sourceApps()
        } catch {
            NSLog("PasteMe: 读取来源应用失败：\(error)")
            return []
        }
    }

    var selectedItem: ClipItem? {
        items.first { $0.id == selectedID } ?? items.first
    }

    func didShow() {
        resetting = true
        query = ""
        filters = PanelFilters()
        resetting = false
        focus = .search
        deleted = []
        reload()
        selectedID = items.first?.id
        showCount += 1
    }

    private func reloadUnlessResetting() {
        if !resetting { reload() }
    }

    func reload() {
        do {
            items = try store.items(matching: currentQuery)
        } catch {
            NSLog("PasteMe: 读取历史失败：\(error)")
            items = []
        }
        if !items.contains(where: { $0.id == selectedID }) {
            selectedID = items.first?.id
        }
    }

    func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(current + offset, 0), items.count - 1)
        selectedID = items[next].id
    }

    func paste(_ item: ClipItem? = nil, as mode: PasteMode = .original) {
        guard let item = item ?? selectedItem else { return }
        onPaste(item, mode)
    }

    /// ⌘1…⌘9：粘贴当前列表里的第 n 条。
    func paste(at index: Int, as mode: PasteMode = .original) {
        guard items.indices.contains(index) else { return }
        onPaste(items[index], mode)
    }

    func delete(_ item: ClipItem? = nil) {
        guard let item = item ?? selectedItem else { return }
        let index = items.firstIndex { $0.id == item.id }
        do {
            if let clip = try store.delete(id: item.id) {
                deleted.append(clip)
            }
        } catch {
            NSLog("PasteMe: 删除失败：\(error)")
        }
        reload()
        if let index, !items.isEmpty {
            selectedID = items[min(index, items.count - 1)].id
        }
    }

    /// ⌘Z：恢复最近删除的一条，并选中它。
    func undoDelete() {
        guard let clip = deleted.popLast() else { return }
        do {
            let id = try store.restore(clip)
            reload()
            selectedID = id
        } catch {
            NSLog("PasteMe: 恢复失败：\(error)")
        }
    }
}
