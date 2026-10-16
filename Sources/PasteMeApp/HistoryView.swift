import PasteMeCore
import SwiftUI

/// 面板内容：顶部搜索栏，下方横向排列的卡片。
struct HistoryView: View {
    @Bindable var model: HistoryModel
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 为 false 时前几张卡片处于出现动画的起点（下移、透明）。每次呼出面板先设为 false，再动画到 true。
    @State private var cardsRevealed = true

    /// 只给前几张卡片做依次出现的动画，屏幕外的卡片直接显示。
    private static let staggeredCards = 8
    private static let cardSpacing: CGFloat = 18
    /// 卡片列表左右两端的留白。选中的卡片放大、外面再套一圈光标后，离面板边缘仍有约 20 点。
    private static let sideMargin: CGFloat = 30
    /// 选中的卡片放大到的比例。
    private static let selectedScale: CGFloat = 1.05

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchBar
            if model.items.isEmpty {
                emptyState
            } else {
                cards
            }
        }
        .onChange(of: model.showCount) {
            searchFocused = true
            cardsRevealed = false
            DispatchQueue.main.async {
                withAnimation { cardsRevealed = true }
            }
        }
        .onChange(of: model.focus) { _, focus in searchFocused = focus == .search }
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
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Self.cardSpacing) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        let selected = item.id == model.selectedID
                        ClipCardView(item: item, shortcutIndex: index < 9 ? index + 1 : nil)
                            .scaleEffect(scale(selected: selected))
                            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: selected)
                            .zIndex(selected ? 1 : 0)
                            .modifier(StaggeredAppearance(
                                index: index,
                                revealed: cardsRevealed || index >= Self.staggeredCards,
                                reduceMotion: reduceMotion
                            ))
                            .id(item.id)
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
                                Divider()
                                Button("删除", role: .destructive) {
                                    model.delete(item)
                                    model.focus = .cards
                                }
                            }
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

    private func scale(selected: Bool) -> CGFloat {
        selected ? Self.selectedScale : 1
    }

    /// 画在所有卡片上面的光标，按选中卡片的序号算出位置，选中项变化时滑过去。
    @ViewBuilder
    private var cursor: some View {
        if let index = model.items.firstIndex(where: { $0.id == model.selectedID }) {
            let size = ClipCardView.size
            let outset = SelectionCursor.outset
            SelectionCursor(
                style: model.cursorStyle,
                color: CardStyle(for: model.items[index]).color,
                cardsFocused: model.focus == .cards,
                animating: model.isPanelVisible && !reduceMotion
            )
            .frame(width: size.width + outset * 2, height: size.height + outset * 2)
            .scaleEffect(scale(selected: true))
            .offset(x: CGFloat(index) * (size.width + Self.cardSpacing) - outset)
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.72), value: index)
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
