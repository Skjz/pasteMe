import Foundation
import Observation
import PasteMeCore
import SwiftUI

/// 删除和撤销删除时卡片的动画，由 `CardDust` 实现。`HistoryModel` 在列表变化前后调用它；
/// 测试里不设置，列表直接变化。
@MainActor
protocol CardRemovalEffect: AnyObject {
    /// 卡片要在这次变化里移动位置（补上空位，或者撤销删除时让位）：返回用的动画。
    /// 实现方据此知道紧接着的布局变化是这个动画，用来算出卡片滑到一半时的位置。
    func slideAnimation() -> Animation?
    /// 卡片将从列表里删除：开始播放它消失的动画，播完时调用 `completion`。
    /// 返回 false 表示没有播放（例如开启了「减少动态效果」），也不会调用 `completion`。
    func playDisappear(
        _ item: ClipItem, at index: Int, selected: Bool, searchText: String,
        completion: @escaping () -> Void
    ) -> Bool
    /// 卡片已经放回列表、处于隐藏状态：播放它出现的动画，结束时调用 `completion`，这时卡片才应显示。
    /// 返回 false 表示不播放，也不会调用 `completion`。
    func playAppear(
        _ item: ClipItem, at index: Int, searchText: String,
        completion: @escaping () -> Void
    ) -> Bool
    /// 停掉所有动画，不调用它们的 `completion`。
    func cancelAll()
}

/// 面板上用按钮和菜单选的筛选条件。搜索框里写的 `type:`、`app:` 不在这里，见 `ClipQuery.parse`。
struct PanelFilters: Equatable {
    /// 空集合表示不限类型。
    var kinds: Set<ClipKind> = []
    var sourceApp: SourceApp?
    var timeRange = TimeRange.all

    var isActive: Bool { !kinds.isEmpty || sourceApp != nil || timeRange != .all }
}

/// 面板上卡片列表里的一格：一张卡片，或者删除后消失动画还没播完的空位。
struct PanelCard: Identifiable, Equatable {
    /// 条目，空位时是被删的条目。卡片变成空位时视图还是同一个，只是不再显示。
    let item: ClipItem
    /// 在 `HistoryModel.items` 里的位置，⌘1…⌘9 按它算。空位为 nil。
    let index: Int?

    var id: Int64 { item.id }
    var isGap: Bool { index == nil }
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
    /// 撤销删除后、出现动画播完之前的卡片。视图不画它们，由动画代替。
    private(set) var hiddenIDs: Set<Int64> = []
    /// 删除后留下的空位（被删的条目）。空位按条目的复制时间排在 `cards` 里，所以总在被删卡片原来的地方，
    /// 撤销时条目也放回同一个地方；中间又删掉或放回别的卡片也不会错位。所有空位的消失动画
    /// 和撤销时的出现动画都播完后才一起去掉，右边的卡片这时一次滑到位，连续删除几张时也不会一格一格地挪；
    /// 颗粒还在飘或聚拢时卡片也不会移动，不会滑进颗粒的范围。
    private(set) var gaps: [ClipItem] = []
    /// 消失动画已经播完、在等其他空位的空位。
    @ObservationIgnored private var finishedGaps: Set<Int64> = []

    /// 删除和撤销删除时卡片的动画。
    @ObservationIgnored weak var removalEffect: CardRemovalEffect?
    /// 带动画地改状态，就是 SwiftUI 的 `withAnimation`。测试替换它，在执行之前检查视图会看到的状态：
    /// SwiftUI 进入 `withAnimation` 前会先渲染之前的改动（见 `PanelFlushTests`）。
    @ObservationIgnored var animate: (Animation?, () -> Void) -> Void = { animation, body in
        withAnimation(animation, body)
    }

    /// 粘贴某个条目。
    @ObservationIgnored var onPaste: (ClipItem, PasteMode) -> Void = { _, _ in }
    /// 打开应用别名窗口，并定位到这个应用（bundle id）。
    @ObservationIgnored var onEditAliases: (String) -> Void = { _ in }

    @ObservationIgnored private let store: ClipStore
    @ObservationIgnored private let now: () -> Date
    /// 按应用的其他名字和别名找来源应用。为 nil 时只按记录时的应用名搜索。
    @ObservationIgnored private let appNames: AppNames?
    /// `didShow` 一次改好搜索词和筛选条件，最后只查询一次。
    @ObservationIgnored private var resetting = false
    /// 本次打开面板后删除的条目，最后删除的在末尾。面板重新打开时清空。
    private var deleted: [DeletedClip] = []

    var canUndoDelete: Bool { !deleted.isEmpty }

    /// 面板上显示的一格格：`items` 中间按复制时间插入还没去掉的空位。
    var cards: [PanelCard] {
        var cards = items.enumerated().map { PanelCard(item: $1, index: $0) }
        guard !gaps.isEmpty else { return cards }
        for gap in gaps {
            let position = cards.firstIndex { Self.comesBefore(gap, $0.item) } ?? cards.count
            cards.insert(PanelCard(item: gap, index: nil), at: position)
        }
        return cards
    }

    /// 和 `ClipStore.items(matching:)` 一样的顺序：复制时间从新到旧，同一时间时 id 大的在前。
    private static func comesBefore(_ a: ClipItem, _ b: ClipItem) -> Bool {
        a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id > b.id
    }

    /// `now` 用于测试时控制“今天”是哪一天。
    init(store: ClipStore, appNames: AppNames? = nil, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.appNames = appNames
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
        if let appNames {
            query = query.resolvingAppNames { appNames.bundleIDs(matching: $0) }
        }
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
            conditions.append("来源应用的名字或别名包含“\(name)”")
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
        gaps = []
        finishedGaps = []
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
        removalEffect?.cancelAll()
        hiddenIDs = []
        gaps = []
        finishedGaps = []
        // 上次打开面板后可能记录了新的来源应用。
        appNames?.historyChanged()
        reload()
        selectedID = items.first?.id
        showCount += 1
    }

    /// 搜索条件变了：列表整个换掉，空位不再对应原来的卡片，一起去掉。
    private func reloadUnlessResetting() {
        guard !resetting else { return }
        gaps = []
        finishedGaps = []
        reload()
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

    /// 删除一个条目，默认是选中的那个。之后选中原来位置上的下一个。
    ///
    /// 条目马上从 `items` 里去掉，紧接着的按键作用于新的列表。有 `removalEffect` 时卡片碎成颗粒飘散，
    /// 原来的地方留一个空位，颗粒散完后空位才去掉、右边的卡片补上来。
    func delete(_ item: ClipItem? = nil) {
        guard let item = item ?? selectedItem else { return }
        let index = items.firstIndex { $0.id == item.id }
        let clip: DeletedClip?
        do {
            clip = try store.delete(id: item.id)
        } catch {
            NSLog("PasteMe: 删除失败：\(error)")
            clip = nil
        }
        guard let clip else { return }
        deleted.append(clip)

        let played = index.map { index in
            removalEffect?.playDisappear(
                item, at: index, selected: item.id == selectedID, searchText: currentQuery.text,
                completion: { [weak self] in self?.closeGap(item.id) }
            ) ?? false
        } ?? false
        // 视图看到的状态要在一个 animate（withAnimation）里一次改完。SwiftUI 进入 withAnimation 前会先渲染之前的改动，
        // 如果先加了空位、再重新查询，中间会有一帧被删的条目在 cards 里出现两次，后面的卡片被挤开一格。
        // 留了空位时其他卡片不动；没有动画时（「减少动态效果」）右边的卡片直接补上来。
        animate(played ? nil : removalEffect?.slideAnimation()) {
            // 正在出现的卡片又被删除时，它的出现动画已被取代，不会再来取消隐藏。
            hiddenIDs.remove(item.id)
            reload()
            if played {
                gaps.append(item)
            }
            if let index, !items.isEmpty {
                selectedID = items[min(index, items.count - 1)].id
            }
        }
        // 被删的可能正是其他空位在等的那张正在出现的卡片。
        closeGapsIfAllFinished()
    }

    /// 一个空位的消失动画播完。所有空位都播完时一起去掉，右边的卡片补上来。
    private func closeGap(_ id: Int64) {
        guard gaps.contains(where: { $0.id == id }) else { return }
        finishedGaps.insert(id)
        closeGapsIfAllFinished()
    }

    private func closeGapsIfAllFinished() {
        guard !gaps.isEmpty, hiddenIDs.isEmpty, gaps.allSatisfy({ finishedGaps.contains($0.id) }) else { return }
        animate(removalEffect?.slideAnimation()) {
            gaps = []
        }
        finishedGaps = []
    }

    /// ⌘Z：恢复最近删除的一条，并选中它。有 `removalEffect` 时颗粒飘回来拼成卡片，拼好之前卡片不显示。
    func undoDelete() {
        guard let clip = deleted.popLast() else { return }
        let id: Int64
        do {
            id = try store.restore(clip)
        } catch {
            NSLog("PasteMe: 恢复失败：\(error)")
            return
        }
        animate(removalEffect?.slideAnimation()) {
            hiddenIDs.insert(id)
            // 消失动画还没播完时，卡片回到自己的空位上，其他卡片不用让位。
            gaps.removeAll { $0.id == id }
            reload()
            selectedID = id
        }
        finishedGaps.remove(id)
        let played = items.firstIndex { $0.id == id }.map { index in
            removalEffect?.playAppear(items[index], at: index, searchText: currentQuery.text) { [weak self] in
                self?.hiddenIDs.remove(id)
                // 剩下的空位可能在等这张卡片拼好。
                self?.closeGapsIfAllFinished()
            } ?? false
        } ?? false
        if !played {
            hiddenIDs.remove(id)
            closeGapsIfAllFinished()
        }
    }
}
