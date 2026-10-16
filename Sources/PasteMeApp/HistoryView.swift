import PasteMeCore
import SwiftUI

/// 面板内容：顶部搜索栏，下方横向排列的卡片。
struct HistoryView: View {
    @Bindable var model: HistoryModel
    /// 删除和撤销删除时的颗粒动画：这里记下每张卡片的位置，颗粒画在最上层。
    let dust: CardDust
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 为 false 时前几张卡片处于出现动画的起点（下移、透明）。每次呼出面板先设为 false，再动画到 true。
    @State private var cardsRevealed = true

    /// 只给前几张卡片做依次出现的动画，屏幕外的卡片直接显示。
    private static let staggeredCards = 8
    static let cardSpacing: CGFloat = 18
    /// 卡片列表左右两端的留白。选中的卡片放大、外面再套一圈光标后，离面板边缘仍有约 20 点。
    private static let sideMargin: CGFloat = 30
    /// 选中的卡片放大到的比例。
    static let selectedScale: CGFloat = 1.05
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
            if model.cards.isEmpty {
                emptyState
            } else {
                cards
            }
        }
        .coordinateSpace(.named(CardDust.space))
        .overlay {
            DustOverlay(view: dust.view)
                .allowsHitTesting(false)
        }
        .onChange(of: model.showCount) {
            searchFocused = true
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
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索，或输入 type:图片 app:微信", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
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
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private var hint: String {
        switch model.focus {
        case .search: "← → 选择   ↓ 操作卡片   ↩ 粘贴   ⇧↩ 纯文本   esc 关闭"
        case .cards: "← → 选择   ↑ 回到搜索   ↩ 粘贴   ⌘⌫ 删除   ⌘Z 撤销删除   esc 关闭"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.searchIsEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 36))
            if model.searchIsEmpty {
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
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Self.cardSpacing) {
                    ForEach(Array(model.cards.enumerated()), id: \.element.id) { position, card in
                        cardView(card, position: position, searchText: searchText)
                            .transition(Self.cardTransition)
                            .id(card.id)
                    }
                }
                .padding(.vertical, 10)
                // 卡片在滚动区域里竖直居中，光标也竖直居中，只按序号算横向位置。
                .overlay(alignment: .leading) { cursor }
            }
            // 放大的卡片和光标的光晕会超出滚动区域的上下边，不裁掉。
            .scrollClipDisabled()
            // 左右留白用 contentMargins 而不是 padding：滚动到某张卡片时，scrollTo 也会留出这段距离，
            // 卡片不会贴着面板边缘。
            .contentMargins(.horizontal, Self.sideMargin, for: .scrollContent)
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
        }
        .padding(.bottom, 10)
    }

    /// 一张卡片和它的选中效果、手势、右键菜单。`position` 是在 `cards` 里的位置。
    ///
    /// 删除后颗粒还没散完时，卡片变成空位：还是这个视图、占着原来的地方，只是透明、不接收点击，
    /// 所以右边的卡片不动。换成另一种视图的话，正在播放选中动画的卡片会被多留一会儿、多占一格。
    private func cardView(_ card: PanelCard, position: Int, searchText: String) -> some View {
        let item = card.item
        let selected = item.id == model.selectedID
        let visible = !card.isGap && !model.hiddenIDs.contains(item.id)
        return ClipCardView(item: item, shortcutIndex: card.index.flatMap { $0 < 9 ? $0 + 1 : nil }, searchText: searchText)
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
            .onTapGesture(count: 2) { model.paste(item) }
            .simultaneousGesture(TapGesture().onEnded {
                model.selectedID = item.id
                model.focus = .cards
            })
            .contextMenu {
                Button("粘贴") { model.paste(item) }
                if item.kind == .text {
                    Button("以纯文本粘贴") { model.paste(item, as: .plainText) }
                }
                if let bundleID = item.sourceBundleID {
                    Button("为“\(item.sourceName ?? bundleID)”设置别名…") { model.onEditAliases(bundleID) }
                }
                Divider()
                Button("删除", role: .destructive) {
                    model.delete(item)
                    model.focus = .cards
                }
            }
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
            .scaleEffect(scale(selected: true))
            .offset(x: CGFloat(index) * (size.width + Self.cardSpacing) - outset)
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
