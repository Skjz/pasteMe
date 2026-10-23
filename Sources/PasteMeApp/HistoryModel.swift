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
    /// 卡片将从列表里删除：开始播放它消失的动画，播完时调用 `completion`。`shortcut` 是卡片上现在显示的 ⌘n，
    /// 没有显示时为 nil。返回 false 表示没有播放（例如开启了「减少动态效果」），也不会调用 `completion`。
    func playDisappear(
        _ item: ClipItem, shortcut: Int?, selected: Bool, searchText: String,
        completion: @escaping () -> Void
    ) -> Bool
    /// 卡片已经放回列表、处于隐藏状态：播放它出现的动画，结束时调用 `completion`，这时卡片才应显示。
    /// 返回 false 表示不播放，也不会调用 `completion`。
    func playAppear(
        _ item: ClipItem, shortcut: Int?, searchText: String,
        completion: @escaping () -> Void
    ) -> Bool
    /// 停掉所有动画，不调用它们的 `completion`。
    func cancelAll()
}

/// 面板上用按钮和菜单选的筛选条件。搜索框里写的 `type:`、`app:` 不在这里，见 `ClipQuery.parse`。
struct PanelFilters: Equatable {
    /// 空集合表示不限类型。
    var kinds: Set<ClipKind> = []
    /// 只看这几种文本子类型（#26，从 `@` 候选里选）。空集合表示不限。
    var subtypes: Set<TextSubtype.Category> = []
    var sourceApp: SourceApp?
    var timeRange = TimeRange.all
    /// 只看固定在这几个 Pinboard 中任意一个里的条目。空集合表示不限。
    var pinboardIDs: Set<Int64> = []

    var isActive: Bool {
        !kinds.isEmpty || !subtypes.isEmpty || sourceApp != nil || timeRange != .all || !pinboardIDs.isEmpty
    }
}

/// 搜索框里输入 `@` 后候选列表里的一项，选中后变成筛选条件。
enum FilterSuggestion: Equatable, Identifiable {
    case kind(ClipKind)
    case subtype(TextSubtype.Category)
    case app(SourceApp)
    case pinboard(Pinboard)

    var id: String {
        switch self {
        case .kind(let kind): "kind:\(kind.rawValue)"
        case .subtype(let subtype): "subtype:\(subtype.rawValue)"
        case .app(let app): "app:\(app.bundleID)"
        case .pinboard(let pinboard): "pinboard:\(pinboard.id)"
        }
    }
}

/// 面板要打开预览窗口做的事，由 `PanelController` 交给 `PreviewController`（#10）。
enum PreviewRequest: Equatable {
    /// 空格：看完整内容。
    case show(ClipItem)
    /// 改文字：打开预览，键盘焦点放进正文。
    case edit(ClipItem)
    /// ⌘N：新建一条文本，在当前 Pinboard 里时也固定到这里。
    case newText
}

/// 要打开 Pinboard 编辑窗口做的事，由 `PanelController` 处理（#9）。
enum PinboardEditRequest: Equatable {
    /// 新建 Pinboard，建好后把这个条目固定进去（可以没有）。
    case create(pinning: ClipItem?)
    case rename(Pinboard)
    /// 删除前确认。
    case delete(Pinboard)
}

/// 本次打开面板后可以撤销的移除：在历史里删掉条目，或者在 Pinboard 里把条目拿掉。
enum Removal: Equatable {
    case deleted(DeletedClip)
    case unpinned(UnpinnedClip)
}

/// 面板上卡片列表里的一格：一张卡片，或者删除后消失动画还没播完的空位。
struct PanelCard: Identifiable, Equatable {
    /// 条目，空位时是被删的条目。卡片变成空位时视图还是同一个，只是不再显示。
    let item: ClipItem
    /// 在 `HistoryModel.items` 里的位置。空位为 nil。
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
        didSet {
            guard query != oldValue else { return }
            updateSuggestions()
            reloadUnlessResetting()
        }
    }
    /// 搜索框末尾正在写 `@词` 时的候选项：名字对得上的类型和来源应用。为空时不显示候选列表。
    private(set) var suggestions: [FilterSuggestion] = []
    /// 候选列表里高亮的一项，↩ 选中它。
    private(set) var suggestionIndex = 0
    /// 按 esc 关掉候选列表时 `@` 前面的文字，用来认出是哪个 `@词`。这个词按普通文字搜索，
    /// 直到它被删掉，或者写完了又开始写下一个 `@词`。
    @ObservationIgnored private var dismissedMention: String?
    /// 修改后立即重新查询。面板每次呼出时清空，和搜索词一样。
    var filters = PanelFilters() {
        didSet { if filters != oldValue { reloadUnlessResetting() } }
    }
    var selectedID: Int64? {
        didSet { if selectedID != oldValue { onSelectionChange() } }
    }
    private(set) var items: [ClipItem] = []
    /// 所有 Pinboard，标签按这个顺序排列。每次呼出面板和改动 Pinboard 后重新读取。
    private(set) var pinboards: [Pinboard] = []
    /// 当前的标签：nil 是「历史」，否则是这个 Pinboard 的 id。每次呼出面板时回到「历史」。
    private(set) var pinboardID: Int64?
    /// 正在从面板上拖出的条目，从拖拽开始到结束。
    var draggingID: Int64?
    /// 原样粘贴图片时也附带文件（`Settings.pasteImagesAsFiles`），这时右键菜单不再列出「以文件粘贴」。
    var pastesImagesAsFiles = false
    /// 光标的样式。初始值和修改都来自 `Settings.cursorStyle`，放在这里是为了让视图随之更新。
    var cursorStyle = CursorStyle.breathe
    /// ⌘O 用什么打开文件和文件夹（#51）。初始值和修改都来自 `Settings.fileApp`、`Settings.folderApp`。
    @ObservationIgnored var fileApp = OpenApp.systemDefault
    @ObservationIgnored var folderApp = OpenApp.systemDefault
    /// 面板在屏幕上（包括呼出和收起动画期间）。为 false 时视图停掉一直在跑的动画。
    var isPanelVisible = false
    /// 键盘操作当前作用于搜索框还是卡片列表，视图据此移动键盘焦点。呼出面板时在卡片列表上：
    /// 在卡片上打字也会进入搜索框（`PanelKeymap`），所以一打开就能用方向键、⌘⌫ 操作卡片。
    var focus: PanelFocus = .cards {
        // 编辑标题时焦点去了别处（点进搜索框、点了别的卡片），按保存处理。
        didSet { if oldValue == .title, focus != .title { commitTitle() } }
    }
    /// 正在卡片标题栏里编辑标题的条目（#33），这时焦点是 `.title`。没有在编辑时为 nil。
    private(set) var titleEditingID: Int64?
    /// 标题栏输入框里的文字。
    var titleDraft = ""
    /// 最左边一张完整显示的格子在 `cards` 里的位置，`HistoryView` 滚动时更新。⌘1…⌘9 从这里数起（#39）。
    var firstVisibleCard = 0
    /// 按住 ⌘（或 ⇧⌘）已经超过 `shortcutHintDelay`，卡片上显示 ⌘1…⌘9（#39）。
    private(set) var shortcutKeysHeld = false
    /// 每次面板弹出时加一，视图据此同步焦点、重新播放卡片出现的动画。
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
    /// 过一段时间再执行，用来推迟显示 ⌘1…⌘9。测试替换它，自己决定什么时候执行。
    @ObservationIgnored var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { action() }
        }
    }

    /// 粘贴某个条目。
    @ObservationIgnored var onPaste: (ClipItem, PasteMode) -> Void = { _, _ in }
    /// 把条目写进剪贴板，不粘贴，也不移到历史最前（#35）。
    @ObservationIgnored var onCopy: (ClipItem) -> Void = { _ in }
    /// 收起面板，按 `OpenPlan` 打开链接、文件和文件夹（#51）。
    @ObservationIgnored var onOpen: (OpenPlan) -> Void = { _ in }
    /// 这个 bundle id 的应用装了没有。测试替换它。
    @ObservationIgnored var isInstalled: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    /// 路径现在是文件还是文件夹，不在了是 nil。测试替换它。
    @ObservationIgnored var pathKind: (String) -> OpenPlan.PathKind? = OpenPlan.pathKind(atPath:)
    /// 打开应用别名窗口，并定位到这个应用（bundle id）。
    @ObservationIgnored var onEditAliases: (String) -> Void = { _ in }
    /// 打开预览窗口。
    @ObservationIgnored var onPreview: (PreviewRequest) -> Void = { _ in }
    /// 打开 Pinboard 的新建、重命名、删除确认窗口。
    @ObservationIgnored var onEditPinboard: (PinboardEditRequest) -> Void = { _ in }
    /// 开始从面板上拖出一张卡片（鼠标按下后移动了一段距离）。
    @ObservationIgnored var onBeginDrag: (ClipItem) -> Void = { _ in }
    /// 改了条目的文字：链接改了网址后可以重新获取预览。
    @ObservationIgnored var onEdited: (Int64) -> Void = { _ in }
    /// 在屏幕上短暂提示一句话，例如“已固定到「工作」”。参数是文字和 SF Symbol 的名字。
    @ObservationIgnored var onNotice: (String, String) -> Void = { _, _ in }
    /// 选中项变了。预览窗口开着时跟着换内容。
    @ObservationIgnored var onSelectionChange: () -> Void = {}
    /// 要在卡片标题栏里编辑标题了：预览开着时先关掉它，免得关闭时把旧标题存回去。
    @ObservationIgnored var onWillEditTitle: () -> Void = {}

    @ObservationIgnored private let store: ClipStore
    /// 记住 ⌘P 用的 Pinboard。为 nil 时（测试）只在内存里记。
    @ObservationIgnored private let settings: PasteMeCore.Settings?
    @ObservationIgnored private var lastPinboardID: Int64?
    @ObservationIgnored private let now: () -> Date
    /// 按应用的其他名字和别名找来源应用。为 nil 时只按记录时的应用名搜索。
    @ObservationIgnored private let appNames: AppNames?
    /// `didShow` 一次改好搜索词和筛选条件，最后只查询一次。
    @ObservationIgnored private var resetting = false
    /// 在历史里最多显示多少条。「在历史里查看」更早的条目时临时加大，读到它后面再多 100 条。
    @ObservationIgnored private var historyLimit = HistoryModel.defaultLimit
    private static let defaultLimit = 200
    /// 拖动排序改了 Pinboard 里的顺序，还没有写进数据库。
    @ObservationIgnored private var reorderPending = false
    /// 这次打开面板后最后一次 ⌘C 拷贝的条目，面板收起时移到历史最前（#35）。
    @ObservationIgnored private(set) var copiedID: Int64?
    /// 现在按着 ⌘ 或 ⇧⌘，不管按了多久。
    @ObservationIgnored private var shortcutKeysDown = false
    /// 每次按下、松开 ⌘ 时加一，用来认出已经作废的那次推迟显示。
    @ObservationIgnored private var shortcutKeysGeneration = 0
    /// 本次打开面板后、在当前标签里删除或拿掉的条目，最后的在末尾。面板重新打开或切换标签时清空。
    private var removals: [Removal] = []

    var canUndoDelete: Bool { !removals.isEmpty }

    /// 当前标签对应的 Pinboard，在「历史」里时为 nil。
    var currentPinboard: Pinboard? { pinboards.first { $0.id == pinboardID } }

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

    /// 和 `ClipStore.items(matching:)` 一样的顺序：Pinboard 里按固定的位置，其余按复制时间从新到旧，
    /// 同一时间时 id 大的在前。
    private static func comesBefore(_ a: ClipItem, _ b: ClipItem) -> Bool {
        if let x = a.pinOrder, let y = b.pinOrder, x != y { return x < y }
        return a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id > b.id
    }

    /// `now` 用于测试时控制“今天”是哪一天。
    init(store: ClipStore, appNames: AppNames? = nil, settings: PasteMeCore.Settings? = nil, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.appNames = appNames
        self.settings = settings
        self.lastPinboardID = settings?.lastPinboardID
        self.now = now
    }

    /// 没有搜索词，也没有筛选条件。
    var searchIsEmpty: Bool { query.isEmpty && !filters.isActive }

    /// 候选列表显示在搜索框下面：焦点在搜索框上，并且有候选项。
    var showsSuggestions: Bool { focus == .search && !suggestions.isEmpty }

    /// 搜索框里的文字和面板上的筛选条件合起来的查询条件。
    var currentQuery: ClipQuery {
        // Pinboard 不会太大，全部列出来；拖动排序也要看到全部条目才能写回顺序。
        var query = ClipQuery.parse(searchInput, limit: pinboardID == nil ? historyLimit : 2_000)
        query.pinboardID = pinboardID
        if !filters.pinboardIDs.isEmpty {
            query.inPinboards = filters.pinboardIDs
        }
        if !filters.kinds.isEmpty {
            query = query.restricting(to: filters.kinds)
        }
        if !filters.subtypes.isEmpty {
            query = query.restricting(toSubtypes: filters.subtypes)
        }
        query.sourceBundleID = filters.sourceApp?.bundleID
        (query.createdFrom, query.createdBefore) = filters.timeRange.bounds(now: now())
        if let appNames {
            query = query.resolvingAppNames { appNames.bundleIDs(matching: $0) }
        }
        return query
    }

    /// 搜索框里要按文字和 `type:`、`app:` 解析的部分。有候选项时正在写的 `@词` 还不算：
    /// 选好之前不按它搜索，列表不会因为多打了一个字就变空。
    private var searchInput: String {
        guard !suggestions.isEmpty, let mention = FilterMention(in: query) else { return query }
        return mention.remainder
    }

    /// 当前起作用的条件，例如 ["类型为图片", "来自微信"]，没有结果时用来说明原因。
    var activeConditions: [String] {
        let query = currentQuery
        var conditions: [String] = []
        if let kinds = query.kinds {
            let names = ClipKind.allCases.filter(kinds.contains).map(\.title)
            conditions.append(names.isEmpty ? "类型条件没有交集" : "类型为" + names.joined(separator: "或"))
        }
        if let subtypes = query.textSubtypes {
            let names = TextSubtype.Category.allCases.filter(subtypes.contains).map(\.title)
            conditions.append(names.isEmpty ? "子类型条件没有交集" : "是" + names.joined(separator: "或"))
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
        let boards = pinboards.filter { filters.pinboardIDs.contains($0.id) }.map { "「\($0.name)」" }
        if !boards.isEmpty {
            conditions.append("固定在" + boards.joined(separator: "或") + "里")
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

    private func updateSuggestions() {
        guard let mention = FilterMention(in: query) else {
            dismissedMention = nil
            suggestions = []
            return
        }
        let found = mention.remainder == dismissedMention ? [] : suggestions(matching: mention.text)
        if found != suggestions {
            suggestions = found
            suggestionIndex = 0
        }
    }

    /// 名字以 `text` 开头的类型和文本子类型，名字包含 `text` 的 Pinboard，以及名字或别名包含 `text` 的来源应用。
    /// `text` 为空时列出全部。
    private func suggestions(matching text: String) -> [FilterSuggestion] {
        let apps = appNames?.apps(matching: text)
            ?? sourceApps().filter { text.isEmpty || $0.name.localizedCaseInsensitiveContains(text) }
        let boards = pinboards.filter { text.isEmpty || $0.name.localizedCaseInsensitiveContains(text) }
        return ClipKind.matching(text).map(FilterSuggestion.kind)
            + TextSubtype.Category.matching(text).map(FilterSuggestion.subtype)
            + boards.map(FilterSuggestion.pinboard)
            + apps.map(FilterSuggestion.app)
    }

    /// ↑ ↓：在候选列表里移动高亮，到头时停住。
    func moveSuggestion(by offset: Int) {
        guard !suggestions.isEmpty else { return }
        suggestionIndex = min(max(suggestionIndex + offset, 0), suggestions.count - 1)
    }

    /// 选中一个候选项，默认是高亮的那个：搜索框里去掉 `@词`，候选项变成筛选条件，和用筛选按钮选的一样。
    func acceptSuggestion(_ suggestion: FilterSuggestion? = nil) {
        let highlighted = suggestions.indices.contains(suggestionIndex) ? suggestions[suggestionIndex] : nil
        guard let mention = FilterMention(in: query), let chosen = suggestion ?? highlighted else { return }
        resetting = true
        query = mention.remainder
        switch chosen {
        case .kind(let kind): filters.kinds.insert(kind)
        case .subtype(let subtype): filters.subtypes.insert(subtype)
        case .app(let app): filters.sourceApp = app
        case .pinboard(let pinboard): filters.pinboardIDs.insert(pinboard.id)
        }
        resetting = false
        reloadUnlessResetting()
    }

    /// esc：关掉候选列表，正在写的 `@词` 改按普通文字搜索，例如要搜 `@gmail.com` 时。
    func dismissSuggestions() {
        guard !suggestions.isEmpty, let mention = FilterMention(in: query) else { return }
        dismissedMention = mention.remainder
        suggestions = []
        reloadUnlessResetting()
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
        titleEditingID = nil
        copiedID = nil
        focus = .cards
        // 卡片从最前面开始显示（`HistoryView` 滚回开头），⌘1 是最新的一条。按着的修饰键由 `PanelController` 接着告诉模型。
        firstVisibleCard = 0
        shortcutKeysDown = false
        shortcutKeysGeneration += 1
        shortcutKeysHeld = false
        pinboardID = nil
        historyLimit = Self.defaultLimit
        draggingID = nil
        reorderPending = false
        forgetRemovals()
        // 上次打开面板后可能记录了新的来源应用。
        appNames?.historyChanged()
        reloadPinboards()
        reload()
        selectedID = items.first?.id
        showCount += 1
    }

    /// 撤销记录、动画和空位都作废：重新打开面板，或者换了标签。
    private func forgetRemovals() {
        removals = []
        removalEffect?.cancelAll()
        hiddenIDs = []
        gaps = []
        finishedGaps = []
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
        // 正在编辑标题的卡片不在列表里了（例如换了筛选条件），输入框也没了：按保存处理。
        if let id = titleEditingID, !items.contains(where: { $0.id == id }) {
            commitTitle()
        }
    }

    func reloadPinboards() {
        do {
            pinboards = try store.pinboards()
        } catch {
            NSLog("PasteMe: 读取 Pinboard 失败：\(error)")
            pinboards = []
        }
        if let pinboardID, !pinboards.contains(where: { $0.id == pinboardID }) {
            showTab(nil)
        }
        filters.pinboardIDs.formIntersection(pinboards.map(\.id))
    }

    func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(current + offset, 0), items.count - 1)
        selectedID = items[next].id
    }

    // MARK: - 标签和 Pinboard

    /// 切换到「历史」（nil）或某个 Pinboard。搜索词和筛选条件保留，在新的标签里接着搜索；撤销记录清空。
    func showTab(_ pinboardID: Int64?) {
        guard pinboardID != self.pinboardID else { return }
        commitTitle()
        finishReordering()
        self.pinboardID = pinboardID
        historyLimit = Self.defaultLimit
        forgetRemovals()
        reload()
        selectedID = items.first?.id
    }

    /// ⌘← ⌘→，或面板开着时再按 ⇧⌘V：在「历史」和各个 Pinboard 之间切换，到头后从另一头接着。
    func cycleTab(by offset: Int) {
        let tabs: [Int64?] = [nil] + pinboards.map(\.id)
        let current = tabs.firstIndex(of: pinboardID) ?? 0
        let count = tabs.count
        showTab(tabs[((current + offset) % count + count) % count])
    }

    /// 把条目（默认是选中的）固定到 Pinboard，并记下这个 Pinboard 给 ⌘P 用。
    func pin(_ item: ClipItem? = nil, to pinboard: Pinboard) {
        guard let item = item ?? selectedItem else { return }
        do {
            let added = try store.pin(item.id, to: pinboard.id)
            remember(pinboard)
            onNotice(added ? "已固定到「\(pinboard.name)」" : "已经在「\(pinboard.name)」里了", "pin")
        } catch {
            NSLog("PasteMe: 固定失败：\(error)")
        }
        reload()
    }

    /// 右键菜单「固定到」里的勾：勾上就固定，去掉勾就从那个 Pinboard 拿掉。正在看的就是那个 Pinboard 时，
    /// 和 ⌘⌫ 一样播放动画、可以撤销。
    func setPinned(_ pinned: Bool, _ item: ClipItem, in pinboard: Pinboard) {
        if pinned {
            pin(item, to: pinboard)
        } else if pinboardID == pinboard.id {
            delete(item)
        } else {
            do {
                try store.unpin(item.id, from: pinboard.id)
            } catch {
                NSLog("PasteMe: 取消固定失败：\(error)")
            }
            reload()
        }
    }

    /// ⌘P：固定到最近用过的 Pinboard。还没有 Pinboard 时先新建一个。
    func pinToRecentPinboard() {
        guard let item = selectedItem else { return }
        if let pinboard = pinboards.first(where: { $0.id == lastPinboardID }) ?? pinboards.first {
            pin(item, to: pinboard)
        } else {
            onEditPinboard(.create(pinning: item))
        }
    }

    private func remember(_ pinboard: Pinboard) {
        lastPinboardID = pinboard.id
        settings?.lastPinboardID = pinboard.id
    }

    /// 新建 Pinboard，`item` 不为 nil 时把它固定进去。名字是空的时不建。
    @discardableResult
    func createPinboard(named name: String, color: PinboardColor, pinning item: ClipItem? = nil) -> Pinboard? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            let pinboard = try store.createPinboard(name: name, color: color)
            reloadPinboards()
            if let item {
                pin(item, to: pinboard)
            }
            return pinboard
        } catch {
            NSLog("PasteMe: 新建 Pinboard 失败：\(error)")
            return nil
        }
    }

    func renamePinboard(_ pinboard: Pinboard, to name: String, color: PinboardColor) {
        do {
            try store.renamePinboard(pinboard.id, to: name)
            try store.setColor(color, ofPinboard: pinboard.id)
        } catch {
            NSLog("PasteMe: 修改 Pinboard 失败：\(error)")
        }
        reloadPinboards()
    }

    func setColor(_ color: PinboardColor, of pinboard: Pinboard) {
        renamePinboard(pinboard, to: pinboard.name, color: color)
    }

    /// 删除 Pinboard。里面的条目还在历史里。正在看这个 Pinboard 时回到「历史」。
    func deletePinboard(_ pinboard: Pinboard) {
        do {
            try store.deletePinboard(pinboard.id)
        } catch {
            NSLog("PasteMe: 删除 Pinboard 失败：\(error)")
        }
        reloadPinboards()
        reload()
    }

    /// 这个 Pinboard 里有多少个条目，删除前提示用。
    func itemCount(of pinboard: Pinboard) -> Int {
        (try? store.items(matching: ClipQuery(pinboardID: pinboard.id, limit: 100_000)).count) ?? 0
    }

    // MARK: - 拖动

    func beginDrag(_ item: ClipItem) {
        // 在标题栏的输入框里拖动是选择文字。
        guard item.id != titleEditingID else { return }
        onBeginDrag(item)
    }

    /// 能不能拖动卡片改顺序：在 Pinboard 里、没有搜索和筛选（看到的是全部条目），也没有正在播放的删除动画。
    var canReorder: Bool { pinboardID != nil && searchIsEmpty && gaps.isEmpty && hiddenIDs.isEmpty }

    /// 拖动排序：正在拖的卡片挪到 `target` 现在的位置，其他卡片让开。松手后 `finishReordering()` 写进数据库。
    func moveDraggedCard(to target: ClipItem) {
        guard canReorder, let dragged = draggingID, dragged != target.id,
              let from = items.firstIndex(where: { $0.id == dragged }),
              let to = items.firstIndex(where: { $0.id == target.id })
        else { return }
        animate(SpringCurve.slide.animation) {
            items.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
        }
        reorderPending = true
    }

    /// 拖拽结束（放下、取消或拖到面板外）：拖动排序改过顺序时写进数据库。
    func endDrag() {
        draggingID = nil
        finishReordering()
    }

    private func finishReordering() {
        guard reorderPending, let pinboardID else { return }
        reorderPending = false
        do {
            try store.setOrder(items.map(\.id), inPinboard: pinboardID)
        } catch {
            NSLog("PasteMe: 保存 Pinboard 的顺序失败：\(error)")
        }
        reload()
    }

    /// 把拖着的卡片放到某个 Pinboard 的标签上：固定进去。
    func dropDraggedCard(on pinboard: Pinboard) -> Bool {
        guard let id = draggingID, let item = items.first(where: { $0.id == id }) else { return false }
        pin(item, to: pinboard)
        return true
    }

    // MARK: - 在历史里查看

    /// 能不能「在历史里查看」：在搜索、筛选或 Pinboard 里，选中的条目在历史里的位置看不到。
    var canShowInHistory: Bool { pinboardID != nil || !searchIsEmpty }

    /// 在历史里查看：清空搜索和筛选，回到「历史」，选中这个条目，前后是和它挨着复制的内容。
    func showInHistory(_ item: ClipItem? = nil) {
        guard let item = item ?? selectedItem else { return }
        let position = (try? store.historyPosition(of: item.id)) ?? 0
        finishReordering()
        resetting = true
        query = ""
        filters = PanelFilters()
        resetting = false
        pinboardID = nil
        forgetRemovals()
        historyLimit = max(Self.defaultLimit, position + 100)
        reload()
        selectedID = item.id
        focus = .cards
    }

    // MARK: - 转换（#27）

    /// 条目可以做的转换。要读出完整内容，只在打开「转换」菜单时调用。
    func conversionOptions(for item: ClipItem) -> [ConversionOption] {
        guard item.kind == .text || item.kind == .link,
              let text = (try? store.content(id: item.id))?.text
        else { return [] }
        return TextConverter.options(for: text, subtype: item.textSubtype)
    }

    /// 转换条目：结果作为新条目记录到历史最前面并选中，原条目不变，按回车就能粘贴。
    /// 和 ⌘N 新建的文本一样不记来源应用，它不是从别的应用复制来的。结果和已有的条目相同时，按正常规则把那条移到最前面。
    /// 在 Pinboard 里或者有筛选时，先回到没有筛选的「历史」，否则可能看不到结果。
    func convert(_ item: ClipItem, using conversion: TextConversion) {
        do {
            guard let text = try store.content(id: item.id)?.text,
                  let result = TextConverter.convert(text, subtype: item.textSubtype, using: conversion)
            else {
                onNotice("这一条没法这样转换", "exclamationmark.triangle")
                return
            }
            try record(result)
        } catch {
            NSLog("PasteMe: 转换失败：\(error)")
        }
    }

    /// 把转换或计算出的结果记到历史最前面并选中。解码出来是一个网址时记成链接，和复制一个网址一样。
    private func record(_ result: String) throws {
        let isLink = PasteboardCodec.isWebLink(result)
        let content = isLink
            ? ClipContent(kind: .link, text: result.trimmingCharacters(in: .whitespacesAndNewlines))
            : ClipContent(kind: .text, text: result)
        let id = try store.insert(content, source: nil, at: now())
        if isLink { onEdited(id) }
        guard let recorded = try store.item(id: id) else { return }
        showInHistory(recorded)
    }

    // MARK: - 哈希值（#37）

    /// 右键菜单里列不列出「计算 MD5」这几项：文件条目才有；有文件夹时不列出，文件夹永远算不了。
    /// 文件不在了时照样列出，后面写明原因（`hashUnavailableReason`）：用户以为能算，要知道为什么不行。
    func offersHash(for item: ClipItem) -> Bool {
        item.kind == .file && !HashInput.includesFolder(item.filePaths)
    }

    /// 文件条目算不了哈希值的原因（文件不在了、是文件夹），菜单里写在后面。能算时为 nil。
    func hashUnavailableReason(for item: ClipItem) -> String? {
        item.kind == .file ? HashInput.unavailableReason(forFiles: item.filePaths) : nil
    }

    /// 计算条目的哈希值：文本和链接算文字按 UTF-8 编码后的字节，文件算文件内容。在后台计算，面板不卡；
    /// 算完后结果和转换一样记成一条新的文本条目，放到历史最前面并选中。返回后台的任务，测试用来等它算完。
    @discardableResult
    func computeHash(_ item: ClipItem, using algorithm: HashAlgorithm) -> Task<Void, Never>? {
        let input: HashInput
        switch item.kind {
        case .text, .link:
            guard let text = (try? store.content(id: item.id))?.text else { return nil }
            input = .text(text)
        case .file:
            guard hashUnavailableReason(for: item) == nil else { return nil }
            input = .files(item.filePaths.map { URL(fileURLWithPath: $0) })
        case .image:
            return nil
        }
        if input.fileSize > Self.largeFileSize {
            onNotice("正在计算 \(algorithm.title)…", "number")
        }
        return Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { try algorithm.digest(of: input) }.result
            guard let self else { return }
            do {
                try self.record(try result.get())
            } catch {
                NSLog("PasteMe: 计算 \(algorithm.title) 失败：\(error)")
                self.onNotice("算不出 \(algorithm.title)：文件读取失败", "exclamationmark.triangle")
            }
        }
    }

    /// 超过这么大的文件，开始计算时先提示一下，几个 GB 的文件要算好几秒。
    private static let largeFileSize = 200 * 1024 * 1024

    // MARK: - 预览和编辑

    func preview(_ item: ClipItem? = nil) {
        guard let item = item ?? selectedItem else { return }
        onPreview(.show(item))
    }

    func edit(_ item: ClipItem? = nil) {
        guard let item = item ?? selectedItem, item.kind == .text || item.kind == .link else { return }
        onPreview(.edit(item))
    }

    // MARK: - 标题（#33）

    /// 起标题、改标题：选中这张卡片，它的标题栏变成输入框，已有的标题全选。不用打开预览。
    func rename(_ item: ClipItem? = nil) {
        guard let item = item ?? selectedItem, items.contains(where: { $0.id == item.id }) else { return }
        commitTitle()
        onWillEditTitle()
        selectedID = item.id
        titleDraft = item.title ?? ""
        titleEditingID = item.id
        focus = .title
    }

    /// 保存标题栏里输入的标题，焦点回到卡片上。清空了就是去掉标题，标题栏恢复显示类型。
    func commitTitle() {
        guard let id = titleEditingID else { return }
        titleEditingID = nil
        if focus == .title { focus = .cards }
        do {
            try store.setTitle(titleDraft, id: id)
        } catch {
            NSLog("PasteMe: 保存标题失败：\(error)")
        }
        reload()
    }

    /// esc：不保存，标题栏恢复原样。
    func cancelTitle() {
        guard titleEditingID != nil else { return }
        titleEditingID = nil
        focus = .cards
    }

    func newText() {
        onPreview(.newText)
    }

    /// 完整内容，预览用。
    func content(of id: Int64) -> ClipContent? {
        try? store.content(id: id)
    }

    /// 保存预览里改过的文字和标题。`text` 为 nil 时不改文字。和其他条目内容相同时合并（见 `ClipStore.updateText`）。
    func saveEdits(of id: Int64, text: String?, rtf: Data?, title: String?) {
        do {
            if let text, try store.updateText(text, rtf: rtf, id: id) {
                onEdited(id)
            }
            try store.setTitle(title, id: id)
        } catch {
            NSLog("PasteMe: 保存修改失败：\(error)")
        }
        reload()
    }

    /// ⌘N 写好的新文本：存进历史并排在最前，在 Pinboard 里时也固定到这里，然后选中它。空的不存。
    func addText(_ text: String, rtf: Data?, title: String?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let id = try store.insert(ClipContent(kind: .text, text: text, rtf: rtf), source: nil, at: now())
            try store.setTitle(title, id: id)
            if let pinboardID {
                try store.pin(id, to: pinboardID)
            }
            reload()
            selectedID = id
        } catch {
            NSLog("PasteMe: 新建文本失败：\(error)")
        }
    }

    // MARK: - 粘贴

    func paste(_ item: ClipItem? = nil, as mode: PasteMode = .original) {
        guard let item = item ?? selectedItem else { return }
        onPaste(item, mode)
    }

    /// ⌘C、右键菜单「拷贝」（#35）：把条目写进剪贴板，用户之后自己粘贴。面板不收起，卡片也不动：
    /// 条目等面板收起时（`panelWillHide`）才移到历史最前，下次打开面板时在最前面。
    func copy(_ item: ClipItem? = nil) {
        guard let item = item ?? selectedItem else { return }
        onCopy(item)
        copiedID = item.id
        onNotice("已拷贝", "doc.on.doc")
    }

    // MARK: - 打开（#51）

    /// 条目要怎么打开，右键菜单用它写菜单项。文本和图片没有可打开的东西，为 nil。`app` 是右键菜单
    /// 「打开方式」里选的应用，文件和文件夹都用它；为 nil 时按设置。
    /// 读完整的内容：卡片上的 `preview` 只有前 2000 个字符，长网址、很多文件时后面的会被截掉。
    func openPlan(for item: ClipItem, using app: OpenApp? = nil) -> OpenPlan? {
        guard item.kind == .link || item.kind == .file else { return nil }
        let text = (try? store.content(id: item.id))?.text
        return OpenPlan.make(
            kind: item.kind, text: text, fileApp: app ?? fileApp, folderApp: app ?? folderApp,
            isInstalled: isInstalled, pathKind: pathKind
        )
    }

    /// 右键菜单「打开方式」里列出的应用：装了的都列出来。只有文件条目有。
    func openApps(for item: ClipItem) -> [OpenApp] {
        guard item.kind == .file else { return [] }
        return OpenApp.allCases.filter { $0.isAvailable(isInstalled: isInstalled) }
    }

    /// ⌘O、右键菜单「打开」「打开方式」：打开链接、文件和文件夹，面板收起。文件都不在了时面板不收起，只提示；
    /// 有一部分不在时打开还在的，再提示找不到几个。
    func open(_ item: ClipItem? = nil, using app: OpenApp? = nil) {
        guard let item = item ?? selectedItem, let plan = openPlan(for: item, using: app) else { return }
        if let reason = plan.unavailableReason {
            onNotice(reason, "exclamationmark.triangle")
            return
        }
        onOpen(plan)
        if plan.missing > 0 {
            onNotice("有 \(plan.missing) 个文件已经不在了", "exclamationmark.triangle")
        }
    }

    /// 面板开始收起：保存标题栏里正在输入的标题，把拷贝过的条目移到历史最前。
    /// 已经显示的 ⌘1…⌘9 跟着面板滑出去，不在收起动画里淡出；还没到时间的不再显示。
    func panelWillHide() {
        shortcutKeysDown = false
        shortcutKeysGeneration += 1
        commitTitle()
        if let id = copiedID {
            copiedID = nil
            do {
                try store.touch(id: id, at: now())
            } catch {
                NSLog("PasteMe: 移动拷贝的条目失败：\(error)")
            }
        }
    }

    /// 收起动画播完、面板已经不在屏幕上：这时才去掉还显示着的 ⌘1…⌘9，下次呼出时不在呼出动画里淡出。
    func panelDidHide() {
        if shortcutKeysHeld { shortcutKeysHeld = false }
    }

    /// ⌘1…⌘9：粘贴从第一张完整显示的卡片数起的第 `index + 1` 条，和卡片上显示的 ⌘n 一致（#39）。
    func paste(at index: Int, as mode: PasteMode = .original) {
        let index = firstShortcutIndex + index
        guard items.indices.contains(index) else { return }
        onPaste(items[index], mode)
    }

    // MARK: - ⌘1…⌘9 的提示（#39）

    /// 按住多久才显示 ⌘1…⌘9：快速按 ⌘C、⌘R 这类组合键，或者按 ⇧⌘V 呼出面板后马上松开时，提示不会闪一下。
    static let shortcutHintDelay: TimeInterval = 0.2

    /// 卡片右下角显示 ⌘1…⌘9。编辑标题时 ⌘数字 交给输入框，不显示。
    var showsShortcutHints: Bool { shortcutKeysHeld && focus != .title }

    /// ⌘1 对应的条目在 `items` 里的位置：第一张完整显示的卡片，它前面的空位不算。
    var firstShortcutIndex: Int {
        guard !gaps.isEmpty else { return min(firstVisibleCard, items.count) }
        return cards.dropFirst(firstVisibleCard).first { !$0.isGap }?.index ?? items.count
    }

    /// 卡片上显示的 ⌘n。`index` 是条目在 `items` 里的位置（空位为 nil），`first` 是 `firstShortcutIndex`，
    /// 不显示提示时传 nil。不在 ⌘1…⌘9 里的为 nil。
    static func shortcutNumber(forItemAt index: Int?, first: Int?) -> Int? {
        guard let index, let first, (first..<first + 9).contains(index) else { return nil }
        return index - first + 1
    }

    /// `items` 里这个位置的卡片现在显示的 ⌘n，删除和撤销的动画照着画。
    private func shortcutNumber(forItemAt index: Int) -> Int? {
        Self.shortcutNumber(forItemAt: index, first: showsShortcutHints ? firstShortcutIndex : nil)
    }

    /// 面板上按着的修饰键变了。`held` 表示按着 ⌘ 或 ⇧⌘（`PanelKeymap.showsShortcutHints`）：
    /// 一直按着 `shortcutHintDelay` 才显示提示，松开或者又按了 ⌥、⌃ 时马上隐藏。
    func shortcutKeysChanged(held: Bool) {
        guard held != shortcutKeysDown else { return }
        shortcutKeysDown = held
        shortcutKeysGeneration += 1
        guard held else {
            if shortcutKeysHeld { shortcutKeysHeld = false }
            return
        }
        let generation = shortcutKeysGeneration
        schedule(Self.shortcutHintDelay) { [weak self] in
            guard let self, self.shortcutKeysGeneration == generation else { return }
            self.shortcutKeysHeld = true
        }
    }

    /// 删除一个条目，默认是选中的那个。在 Pinboard 里只是把条目从这个 Pinboard 拿掉，条目还在历史里。
    /// 之后选中原来位置上的下一个。
    ///
    /// 条目马上从 `items` 里去掉，紧接着的按键作用于新的列表。有 `removalEffect` 时卡片碎成颗粒飘散，
    /// 原来的地方留一个空位，颗粒散完后空位才去掉、右边的卡片补上来。
    func delete(_ item: ClipItem? = nil) {
        guard let item = item ?? selectedItem else { return }
        let index = items.firstIndex { $0.id == item.id }
        let removal: Removal?
        do {
            if let pinboardID {
                removal = try store.unpin(item.id, from: pinboardID).map(Removal.unpinned)
            } else {
                removal = try store.delete(id: item.id).map(Removal.deleted)
            }
        } catch {
            NSLog("PasteMe: 删除失败：\(error)")
            removal = nil
        }
        guard let removal else { return }
        removals.append(removal)

        let played = index.map { index in
            removalEffect?.playDisappear(
                item, shortcut: shortcutNumber(forItemAt: index), selected: item.id == selectedID,
                searchText: currentQuery.text,
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

    /// ⌘Z：恢复最近删除（或从 Pinboard 拿掉）的一条，并选中它。有 `removalEffect` 时颗粒飘回来拼成卡片，拼好之前卡片不显示。
    func undoDelete() {
        guard let removal = removals.popLast() else { return }
        let id: Int64
        do {
            switch removal {
            case .deleted(let clip):
                id = try store.restore(clip)
            case .unpinned(let pin):
                try store.restorePin(pin)
                id = pin.clipID
            }
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
            removalEffect?.playAppear(
                items[index], shortcut: shortcutNumber(forItemAt: index), searchText: currentQuery.text
            ) { [weak self] in
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
