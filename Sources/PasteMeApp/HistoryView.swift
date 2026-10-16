import PasteMeCore
import SwiftUI

/// 面板内容：顶部搜索栏，下方横向排列的卡片。
struct HistoryView: View {
    @Bindable var model: HistoryModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchBar
            if model.items.isEmpty {
                emptyState
            } else {
                cards
            }
        }
        .onChange(of: model.showCount) { searchFocused = true }
        .onChange(of: model.query) { model.reload() }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索剪贴板历史", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
            Spacer()
            Text("← → 选择   ↩ 粘贴   ⇧↩ 纯文本   ⌘⌫ 删除   esc 关闭")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 36))
            Text(model.query.isEmpty ? "还没有记录，复制点什么试试" : "没有匹配“\(model.query)”的记录")
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cards: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        ClipCardView(item: item, shortcutIndex: index < 9 ? index + 1 : nil, isSelected: item.id == model.selectedID)
                            .id(item.id)
                            .onTapGesture(count: 2) { model.paste(item) }
                            .simultaneousGesture(TapGesture().onEnded {
                                model.selectedID = item.id
                                searchFocused = true
                            })
                            .contextMenu {
                                Button("粘贴") { model.paste(item) }
                                if item.kind == .text {
                                    Button("以纯文本粘贴") { model.paste(item, as: .plainText) }
                                }
                                Divider()
                                Button("删除", role: .destructive) { model.delete(item) }
                            }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
            }
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
        }
        .padding(.bottom, 14)
    }
}
