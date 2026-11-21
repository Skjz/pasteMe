import PasteMeCore
import SwiftUI
import UniformTypeIdentifiers

/// 面板内容：顶部搜索栏，下方横向排列的卡片。
struct HistoryView: View {
    @Bindable var model: HistoryModel
    /// 删除和撤销删除时的颗粒动画：这里记下每张卡片的位置，颗粒画在最上层。
    let dust: CardDust
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 为 false 时前几张卡片处于出现动画的起点（下移、透明）。每次呼出面板先设为 false，再动画到 true。
    @State private var cardsRevealed = true
    /// 卡片列表滚到了后面，第一张没有完整显示。下次呼出面板时要滚回最前面。
    @State private var scrolledPastFirst = false

    /// 只给前几张卡片做依次出现的动画，屏幕外的卡片直接显示。
    private static let staggeredCards = 8
    nonisolated static let cardSpacing: CGFloat = 18
    /// 每张卡片左边、卡片列表上边多留出的地方，放压在卡片左上角的置顶图钉（#77）。
    /// 点击只送到卡片列表自己的范围里：第一张卡片的图钉伸出左边的那一半落在滚动区域的留白里，选中的卡片放大后
    /// 图钉伸出卡片原来的上边约 16.5 点，超出了原来上面留的 10 点，不留地方就点不到（在真实应用里点过）。
    /// 左边留在每一项里而不是整个列表上：`scrollTo` 按整项对齐留白，卡片离面板边缘仍是 `sideMargin`。
    /// 项与项的间距、左边的留白和滚动区域的上边减掉同样多，卡片的位置不变。
    nonisolated static let badgeRoom: CGFloat = 17
    /// 卡片列表下边的留白。
    private static let bottomRoom: CGFloat = 10
    /// 卡片列表左右两端的留白。选中的卡片放大、外面再套一圈光标后，离面板边缘仍有约 20 点。
    private static let sideMargin: CGFloat = 30
    /// 选中的卡片放大到的比例。
    nonisolated static let selectedScale: CGFloat = 1.05
    /// 卡片和空位都不做淡入淡出：删除时卡片变成同一位置上的空位，颗粒接替了它；空位去掉时本来就看不见，
    /// 而且要立即移除，之后撤销放回同一个条目时才是新视图（`SwiftUIAssumptionTests` 检查）；
    /// 撤销删除时放回的卡片先藏起来（`HistoryModel.hiddenIDs`），等颗粒拼好再显示。
    private static let cardTransition = AnyTransition.asymmetric(
        insertion: .identity,
        removal: .opacity.animation(.linear(duration: 0))
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchBar
                // 候选列表画在卡片上面。
                .zIndex(1)
            if model.cards.isEmpty {
                emptyState
            } else {
                cards
            }
        }
        .coordinateSpace(.named(CardDust.space))
        // 面板上没有控件的地方（搜索栏那一行的空隙、底部的留白）：点了关掉预览。控件和卡片在它前面，
        // 点中它们时轮不到这里。卡片那一排的空隙被滚动区域挡着，由 `PanelController` 按卡片的位置判断（`CardListClick`）。
        .background {
            Color.clear
                .contentShape(.rect)
                .onTapGesture { model.blankClicked() }
        }
        .overlay {
            DustOverlay(view: dust.view)
                .allowsHitTesting(false)
        }
        .onChange(of: model.showCount) {
            // 上次关闭面板时焦点可能还在搜索框里，窗口再次成为 key 时会还给它。
            searchFocused = model.focus == .search
            cardsRevealed = false
            DispatchQueue.main.async {
                withAnimation { cardsRevealed = true }
            }
        }
        .onChange(of: model.focus) { _, focus in searchFocused = focus == .search }
        // 聚拢中的颗粒要跟着卡片的选中状态放大或缩回。
        .onChange(of: model.selectedID, initial: true) { _, id in dust.selectionChanged(to: id) }
        .onChange(of: searchFocused) { _, focused in
            // 用鼠标点进搜索框时，焦点回到搜索框。
            if focused { model.focus = .search }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            PinboardTabs(model: model)
                // 标签多了先截掉提示，再缩搜索框，标签本身不截。
                .fixedSize()
            Divider().frame(height: 16).padding(.horizontal, 4)
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索，输入 @ 筛选", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
                .overlay(alignment: .topLeading) {
                    if model.showsSuggestions {
                        // 列表从搜索框下边再往下 8 点开始。
                        GeometryReader { field in
                            FilterSuggestionList(model: model)
                                .offset(x: -6, y: field.size.height + 8)
                        }
                    }
                }
                // 不设上限时搜索框会占满整行，筛选按钮被挤到最右边，提示也没有位置了。
                .frame(minWidth: 220, maxWidth: 360)
            FilterBar(model: model)
            Spacer(minLength: 12)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                // 面板窄时先截掉提示，不挤占搜索框和筛选按钮。
                .layoutPriority(-1)
                // 只是说明：点在上面和点在空白处一样（`HistoryModel.blankClicked`）。
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private var hint: String {
        if model.showsSuggestions { return "↑ ↓ 选择   ↩ 筛选   esc 取消" }
        switch model.focus {
        case .search: return "← → 选择   ↓ 操作卡片   ↩ 粘贴   ⇧↩ 纯文本   esc 关闭"
        case .title: return "↩ 保存标题   esc 取消"
        case .cards:
            let remove = model.pinboardID == nil ? "⌘⌫ 删除" : "⌘⌫ 移出   拖动排序"
            let tab = model.tabShortcutHint.map { "   \($0)" } ?? ""
            return "空格 预览   ↩ 粘贴   ⌘P 置顶   \(remove)   ⌘Z 撤销\(tab)"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: !model.searchIsEmpty ? "magnifyingglass" : model.pinboardID == nil ? "doc.on.clipboard" : "pin")
                .font(.system(size: 36))
            if model.searchIsEmpty, let pinboard = model.currentPinboard {
                Text("「\(pinboard.name)」里还没有条目")
                Text("在卡片的右键菜单里选「固定到」，或者把卡片拖到这个标签上")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if model.searchIsEmpty {
                Text("还没有记录，复制点什么试试")
            } else {
                Text("没有符合条件的记录")
                Text(model.activeConditions.joined(separator: "、"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cards: some View {
        ScrollViewReader { proxy in
            let searchText = model.currentQuery.text
            // 没按住 ⌘ 时不读滚动位置，滚动时卡片列表不用重新计算。
            let firstShortcut = model.showsShortcutHints ? model.firstShortcutIndex : nil
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Self.cardSpacing - Self.badgeRoom) {
                    ForEach(Array(model.cards.enumerated()), id: \.element.id) { position, card in
                        cardView(card, position: position, searchText: searchText, firstShortcut: firstShortcut)
                            .padding(.leading, Self.badgeRoom)
                            .transition(Self.cardTransition)
                            .id(card.id)
                    }
                }
                .padding(.top, Self.badgeRoom)
                .padding(.bottom, Self.bottomRoom)
                // 卡片在卡片列表里竖直居中（列表可能比卡片高一点），光标也竖直居中，再补上上下留白不一样多的差；
                // 不能从顶上按固定距离放，那样会比卡片高几点。横向按序号算位置。
                .overlay(alignment: .leading) { cursor }
                // ⌘1…⌘9 从第一张完整显示的卡片数起（#39）。滚动时每帧只算出一个序号，跨过一张卡片时才告诉模型。
                .onGeometryChange(for: Int.self) { geometry in
                    Self.firstFullyVisibleCard(contentMinX: geometry.frame(in: .named(Self.scrollSpace)).minX + Self.badgeRoom)
                } action: { first in
                    model.firstVisibleCard = first
                    if scrolledPastFirst != (first > 0) { scrolledPastFirst = first > 0 }
                }
            }
            .coordinateSpace(.named(Self.scrollSpace))
            // 放大的卡片和光标的光晕会超出滚动区域的上下边，不裁掉。
            .scrollClipDisabled()
            // 左右留白用 contentMargins 而不是 padding：滚动到某张卡片时，scrollTo 也会留出这段距离，
            // 卡片不会贴着面板边缘。
            .contentMargins(.leading, Self.sideMargin - Self.badgeRoom, for: .scrollContent)
            .contentMargins(.trailing, Self.sideMargin, for: .scrollContent)
            // 卡片上面原来留 10 点，现在留 `badgeRoom`：滚动区域往上伸出多出来的部分，卡片不往下移。
            .padding(.top, 10 - Self.badgeRoom)
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
            // 选中的卡片置顶或取消置顶后换了位置（#77），选中项没变，上面的不会触发。
            .onChange(of: model.revealSelectionCount) {
                guard let id = model.selectedID else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
            // 呼出面板时从最前面开始显示：上次可能用触控板滚到了后面，而选中项还是第一张，上面的 scrollTo 不会触发。
            // 已经在最前面时不滚：再滚一次，呼出动画会多缺一帧。
            .onChange(of: model.showCount) {
                if scrolledPastFirst, let first = model.cards.first?.id { proxy.scrollTo(first) }
            }
        }
        .padding(.bottom, 10)
    }

    /// 卡片列表滚动区域的坐标系，用来算出滚动到了哪里。
    nonisolated private static let scrollSpace = "cardScroll"

    /// 最左边一张完整显示的格子在 `cards` 里的位置（#39）。`contentMinX` 是卡片列表的左边在滚动区域里的位置，
    /// 往右翻时变成负数。差半个点以内也算完整显示，滚动停在小数位置上时不会少算一张。
    nonisolated static func firstFullyVisibleCard(contentMinX: CGFloat) -> Int {
        let pitch = ClipCardView.size.width + cardSpacing
        return max(0, Int(((-contentMinX - 0.5) / pitch).rounded(.up)))
    }

    /// 一张卡片和它的选中效果、手势、右键菜单。`position` 是在 `cards` 里的位置，`firstShortcut` 是
    /// ⌘1 那张卡片在 `items` 里的位置，不显示 ⌘1…⌘9 时为 nil。
    ///
    /// 删除后颗粒还没散完时，卡片变成空位：还是这个视图、占着原来的地方，只是透明、不接收点击，
    /// 所以右边的卡片不动。换成另一种视图的话，正在播放选中动画的卡片会被多留一会儿、多占一格。
    private func cardView(_ card: PanelCard, position: Int, searchText: String, firstShortcut: Int?) -> some View {
        let item = card.item
        let selected = item.id == model.selectedID
        let visible = !card.isGap && !model.hiddenIDs.contains(item.id)
        let editingTitle = item.id == model.titleEditingID
        return ClipCardView(
            item: item,
            shortcutIndex: HistoryModel.shortcutNumber(forItemAt: card.index, first: firstShortcut),
            searchText: searchText,
            titleField: editingTitle ? AnyView(CardTitleField(model: model, placeholder: item.typeTitle)) : nil
        )
            .scaleEffect(scale(selected: selected))
            .animation(SpringCurve.selection.animation, value: selected)
            // 放在选中动画外面：删除时卡片立即消失，不跟着选中的弹簧慢慢变淡。
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(!card.isGap)
            // 放大之前的位置：颗粒动画自己按选中与否放大。
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(CardDust.space)) } action: {
                dust.cardLaidOut(item.id, at: $0)
            }
            .onDisappear { dust.cardLeft(item.id) }
            .zIndex(selected ? 1 : 0)
            .modifier(StaggeredAppearance(
                index: position,
                revealed: cardsRevealed || position >= Self.staggeredCards,
                reduceMotion: reduceMotion
            ))
            // 编辑标题时，点、双击输入框是移动插入点、选词，不是选中或粘贴卡片。
            .onTapGesture(count: 2) { if !editingTitle { model.paste(item) } }
            .simultaneousGesture(TapGesture().onEnded {
                guard !editingTitle else { return }
                model.selectedID = item.id
                model.focus = .cards
            })
            // 拖出卡片（#12）：交给 AppKit 的拖拽，见 `PanelController.beginDrag`。
            .simultaneousGesture(DragGesture(minimumDistance: 6).onChanged { _ in model.beginDrag(item) })
            // 在 Pinboard 里拖到别的卡片上时换位置。
            .onDrop(of: [.item], delegate: ReorderDropDelegate(item: item, model: model))
            .contextMenu { CardContextMenu(item: item, model: model) }
            // 置顶按钮（#77）放在点击、拖动手势和右键菜单的外面：点它只切换置顶，不选中、不粘贴、不拖走卡片。
            // 所以卡片自己的放大和依次出现的动画要在这里再做一遍，按钮才跟着卡片动。
            .overlay {
                PinToTopBadge(item: item, model: model, enabled: !card.isGap && !editingTitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .scaleEffect(scale(selected: selected))
                    .animation(SpringCurve.selection.animation, value: selected)
                    .opacity(visible ? 1 : 0)
                    .modifier(StaggeredAppearance(
                        index: position,
                        revealed: cardsRevealed || position >= Self.staggeredCards,
                        reduceMotion: reduceMotion
                    ))
            }
            .onHover { inside in model.cardHovered(item.id, inside) }
    }

    private func scale(selected: Bool) -> CGFloat {
        selected ? Self.selectedScale : 1
    }

    /// 画在所有卡片上面的光标，按选中卡片的序号算出位置，选中项变化时滑过去。
    @ViewBuilder
    private var cursor: some View {
        // 按在 `cards` 里的位置算：前面的空位也占一格。
        let cards = model.cards
        if let index = cards.firstIndex(where: { $0.id == model.selectedID && !$0.isGap }) {
            let item = cards[index].item
            let size = ClipCardView.size
            let outset = SelectionCursor.outset
            SelectionCursor(
                style: model.cursorStyle,
                color: CardStyle(for: item).color,
                cardsFocused: model.focus == .cards,
                animating: model.isPanelVisible && !reduceMotion
            )
            .frame(width: size.width + outset * 2, height: size.height + outset * 2)
            // 光标画在卡片上面，会压住选中卡片左上角的置顶图钉（#77）：在图钉周围断开一段。
            .mask { CursorBadgeGap(item: item, model: model, center: CGPoint(x: outset, y: outset)) }
            .scaleEffect(scale(selected: true))
            .offset(x: Self.badgeRoom + CGFloat(index) * (size.width + Self.cardSpacing) - outset, y: (Self.badgeRoom - Self.bottomRoom) / 2)
            // 卡片补位或让位时（这次变化带着动画），光标跟着卡片用同一个动画，一起滑动；
            // 平时（方向键、点击）用光标自己的弹簧。
            .transaction(value: index) { transaction in
                if transaction.animation == nil, !reduceMotion {
                    transaction.animation = SpringCurve.cursor.animation
                }
            }
            .opacity(cardsRevealed ? 1 : 0)
            .animation(cardsRevealed ? .easeOut(duration: 0.25).delay(0.1) : nil, value: cardsRevealed)
        }
    }
}

/// 卡片的右键菜单。单独做成一个视图：写在卡片的 body 里时，SwiftUI 每次画卡片都会把整个菜单
/// （连同「固定到」里每个 Pinboard 的勾）建一遍，呼出面板时 `show()` 多花 7 ms 左右。
private struct CardContextMenu: View {
    let item: ClipItem
    let model: HistoryModel

    var body: some View {
        Button("粘贴") { model.paste(item) }
        if item.kind == .text {
            Button("以纯文本粘贴") { model.paste(item, as: .plainText) }
        }
        if item.kind == .image, !model.pastesImagesAsFiles {
            Button("以文件粘贴") { model.paste(item, as: .file) }
        }
        Button("拷贝") { model.copy(item) }
            .keyboardShortcut("c", modifiers: .command)
        Button("加入 Paste Stack") { model.addToPasteStack(item) }
        if let plan = model.openPlan(for: item) {
            Button(plan.title + (plan.unavailableReason.map { "（\($0)）" } ?? "")) { model.open(item) }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(plan.unavailableReason != nil)
            if plan.unavailableReason == nil, item.kind == .file {
                Menu("打开方式") { OpenWithMenuItems(item: item, model: model) }
            }
        }
        AirDropMenuItem(item: item, model: model)
        Divider()
        Button("预览") { model.preview(item) }
        if item.kind == .text || item.kind == .link {
            Button("编辑…") { model.edit(item) }
        }
        Button(item.title == nil ? "添加标题" : "修改标题") { model.rename(item) }
            .keyboardShortcut("r", modifiers: .command)
        if item.kind == .text || item.kind == .link {
            Menu("转换") { ConversionMenuItems(item: item, model: model) }
        }
        if model.offersHash(for: item) {
            let reason = model.hashUnavailableReason(for: item)
            ForEach(HashAlgorithm.allCases, id: \.self) { algorithm in
                Button("计算 \(algorithm.title)" + (reason.map { "（\($0)）" } ?? "")) {
                    model.computeHash(item, using: algorithm)
                }
                .disabled(reason != nil)
            }
        }
        Button(item.pinnedToTopAt == nil ? "置顶" : "取消置顶") { model.setPinnedToTop(item.pinnedToTopAt == nil, item) }
            .keyboardShortcut("p", modifiers: .command)
        Menu("固定到") {
            ForEach(model.pinboards) { pinboard in
                Toggle(pinboard.name, isOn: Binding(
                    get: { item.pinboardIDs.contains(pinboard.id) },
                    set: { model.setPinned($0, item, in: pinboard) }
                ))
            }
            if !model.pinboards.isEmpty { Divider() }
            Button("新建 Pinboard…") { model.onEditPinboard(.create(pinning: item)) }
        }
        if model.canShowInHistory {
            Button("在历史里查看") { model.showInHistory(item) }
        }
        if let bundleID = item.sourceBundleID {
            Button("为“\(item.sourceName ?? bundleID)”设置别名…") { model.onEditAliases(bundleID) }
        }
        Divider()
        Button(model.currentPinboard.map { "从「\($0.name)」移出" } ?? "删除", role: .destructive) {
            model.delete(item)
            model.focus = .cards
        }
    }
}

/// 在卡片标题栏里编辑标题的输入框（#33）。出现时取得键盘焦点；↩ 和 esc 由 `PanelKeymap` 处理，
/// 焦点去了别处时 `HistoryModel.focus` 改变，按保存处理。
private struct CardTitleField: View {
    @Bindable var model: HistoryModel
    let placeholder: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $model.titleDraft)
            .textFieldStyle(.plain)
            .lineLimit(1)
            .focused($focused)
            // 等这次更新把输入框放进窗口，再让它成为第一响应者；成为第一响应者时已有的文字会全选。
            .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

/// 「转换」子菜单的内容（#27）。单独成一个视图：列出转换要读出完整内容，只在菜单打开时做。
/// ⌘T 弹出的是同样内容的 `NSMenu`（`PanelController.showConversionMenu`）。
/// 右键菜单「隔空投送…」（#68）。单独做成视图，右键打开菜单时才检查文件和系统服务状态。
private struct AirDropMenuItem: View {
    let item: ClipItem
    let model: HistoryModel

    var body: some View {
        let state = model.airDropMenuState(for: item)
        Button(state.title) { model.sendViaAirDrop(item) }
            .disabled(!state.isEnabled)
    }
}

/// 右键菜单「打开方式」（#51）：装了的应用都列出来，选了就用它打开这个条目里的文件和文件夹，不改设置。
/// 系统默认的方式、编辑器、终端之间有分隔线。单独做成视图，子菜单打开时才查装了哪些应用。
private struct OpenWithMenuItems: View {
    let item: ClipItem
    let model: HistoryModel

    var body: some View {
        let apps = model.openApps(for: item)
        let onlyFolders = item.filePaths.allSatisfy { model.pathKind($0) == .folder }
        ForEach(Array(apps.enumerated()), id: \.element) { index, app in
            if index > 0, Self.group(of: apps[index - 1]) != Self.group(of: app) {
                Divider()
            }
            Button(app.title(forFolders: onlyFolders)) { model.open(item, using: app) }
        }
    }

    private static func group(of app: OpenApp) -> Int {
        app == .systemDefault ? 0 : app.isTerminal ? 2 : 1
    }
}

private struct ConversionMenuItems: View {
    let item: ClipItem
    let model: HistoryModel

    var body: some View {
        let options = model.conversionOptions(for: item)
        if options.isEmpty {
            Button(ConversionOption.tooLongNote) {}
                .disabled(true)
        }
        ForEach(Array(options.enumerated()), id: \.element.conversion) { index, option in
            if index > 0, option.conversion == .encodeBase64 { Divider() }
            Button(option.menuTitle(for: item.textSubtype)) { model.convert(item, using: option.conversion) }
                .disabled(option.unavailableReason != nil)
        }
        // 哈希值（#37）不受 1 MB 的限制，在后台计算。
        Divider()
        ForEach(HashAlgorithm.allCases, id: \.self) { algorithm in
            Button(algorithm.title) { model.computeHash(item, using: algorithm) }
        }
    }
}

extension ConversionOption {
    /// 菜单项的名字，做不了时在后面注明原因，例如「ASCII 文本（非 UTF-8）」。
    func menuTitle(for subtype: TextSubtype?) -> String {
        conversion.title(for: subtype) + (unavailableReason.map { "（\($0)）" } ?? "")
    }

    static let tooLongNote = "超过 1 MB，无法转换"
}

/// Pinboard 里拖动排序：拖着的卡片经过别的卡片时换到它的位置，松手时写进数据库（`HistoryModel.endDrag`）。
private struct ReorderDropDelegate: DropDelegate {
    let item: ClipItem
    let model: HistoryModel

    func validateDrop(info: DropInfo) -> Bool {
        model.canReorder && model.draggingID != nil
    }

    func dropEntered(info: DropInfo) {
        model.moveDraggedCard(to: item)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        true
    }
}

/// 卡片左上角的置顶按钮（#77）：置顶的卡片一直显示，点它取消；没置顶的卡片在鼠标移进来时才出现，点它置顶。
///
/// 按钮的中心在卡片的左上角，大半伸到卡片外面，不挡标题。只读鼠标在哪张卡片、哪个按钮上（`showsPinButton`），
/// 鼠标在卡片之间移动时只有这些小视图重新计算，卡片列表不用。不显示时整个按钮不在视图里，
/// 每张卡片不用多带一层材质。
private struct PinToTopBadge: View {
    let item: ClipItem
    let model: HistoryModel
    /// 空位和正在编辑标题的卡片上不出现按钮，已经显示的标记也点不了。
    let enabled: Bool

    static let size: CGFloat = 20

    /// 这张卡片上显示着图钉：置顶了，或者鼠标在卡片或按钮上。光标在图钉周围断开时也按它判断（`CursorBadgeGap`）。
    static func isShowing(_ item: ClipItem, model: HistoryModel, enabled: Bool) -> Bool {
        item.pinnedToTopAt != nil || (enabled && model.showsPinButton(for: item.id))
    }

    var body: some View {
        let pinned = item.pinnedToTopAt != nil
        let showing = Self.isShowing(item, model: model, enabled: enabled)
        ZStack {
            if showing {
                button(pinned: pinned)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: showing)
    }

    private func button(pinned: Bool) -> some View {
        Button {
            model.setPinnedToTop(!pinned, item)
        } label: {
            Image(systemName: "pin.fill")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(45))
                .foregroundStyle(pinned ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: Self.size, height: Self.size)
                .background(Circle().fill(pinned ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(pinned ? 0 : 0.15), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 1.5, y: 0.5)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { inside in model.pinButtonHovered(item.id, inside) }
        .help(pinned ? "取消置顶" : "置顶：排在历史最前面，不进 Pinboard")
        .offset(x: -Self.size / 2, y: -Self.size / 2)
        .allowsHitTesting(enabled)
    }
}

/// 光标的遮罩：选中的卡片显示着置顶图钉时，在图钉周围挖掉一个圆，光标在那里断开，图钉不被盖住。
/// 单独做成一个视图：它读鼠标在哪张卡片上，鼠标移动时只有它重新计算，卡片列表不用。
/// 光标和图钉都按卡片的中心放大，所以在光标自己的坐标里，图钉的中心总是 `center`（卡片的左上角）。
/// 挖洞用奇偶填充的路径（`CursorGapShape`），不用 `blendMode(.destinationOut)`：后者在截图里挖出的圆大了一倍、位置也偏了。
private struct CursorBadgeGap: View {
    let item: ClipItem
    let model: HistoryModel
    let center: CGPoint

    /// 图钉的半径再加上和光标之间的空隙。
    static let radius = PinToTopBadge.size / 2 + 2.5

    var body: some View {
        let showing = PinToTopBadge.isShowing(item, model: model, enabled: model.titleEditingID != item.id)
        CursorGapShape(center: center, radius: showing ? Self.radius : 0)
            .fill(style: FillStyle(eoFill: true))
            .animation(.easeOut(duration: 0.12), value: showing)
    }
}

/// 比自己大一圈的矩形减去一个圆。矩形伸出 `glowReach`：光标的光晕伸在光标外面，遮罩要盖住它，否则光晕会被切掉。
private struct CursorGapShape: Shape {
    var center: CGPoint
    var radius: CGFloat
    static let glowReach: CGFloat = 60

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -Self.glowReach, dy: -Self.glowReach))
        if radius > 0 {
            path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        return path
    }
}

/// 呼出面板时卡片从左到右依次上浮淡入。
private struct StaggeredAppearance: ViewModifier {
    let index: Int
    let revealed: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed || reduceMotion ? 0 : 18)
            .animation(
                revealed ? .spring(response: 0.3, dampingFraction: 0.8).delay(Double(index) * 0.025) : nil,
                value: revealed
            )
    }
}
