import PasteMeCore
import SwiftUI

/// 搜索框里输入 `@` 后弹出的候选列表：名字对得上的类型、Pinboard 和来源应用，选中的变成筛选条件。
/// ↑ ↓ 移动高亮、↩ 或 Tab 选中由 `PanelKeymap` 处理，这里只负责显示和点击。
struct FilterSuggestionList: View {
    let model: HistoryModel

    static let width: CGFloat = 260
    private static let rowHeight: CGFloat = 26
    /// 超过这么多项时列表可以滚动。面板只有 330 点高，列表要留在面板里面。
    private static let visibleRows = 7
    private static let inset: CGFloat = 5

    var body: some View {
        let suggestions = model.suggestions
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        row(suggestion, highlighted: index == model.suggestionIndex)
                            .id(suggestion.id)
                            .onTapGesture { model.acceptSuggestion(suggestion) }
                    }
                }
                .padding(Self.inset)
            }
            .scrollIndicators(suggestions.count > Self.visibleRows ? .automatic : .never)
            .frame(width: Self.width, height: CGFloat(min(suggestions.count, Self.visibleRows)) * Self.rowHeight + Self.inset * 2)
            .onChange(of: model.suggestionIndex) { _, index in
                guard suggestions.indices.contains(index) else { return }
                proxy.scrollTo(suggestions[index].id)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    private func row(_ suggestion: FilterSuggestion, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            icon(suggestion, highlighted: highlighted)
                .frame(width: 16, height: 16)
            Text(title(suggestion))
                .lineLimit(1)
            Spacer(minLength: 8)
            if isActive(suggestion) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
            }
            Text(category(suggestion))
                .font(.system(size: 11))
                .foregroundStyle(highlighted ? Color.white.opacity(0.75) : Color.secondary)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 6).fill(highlighted ? Color.accentColor : Color.clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func icon(_ suggestion: FilterSuggestion, highlighted: Bool) -> some View {
        switch suggestion {
        case .kind(let kind):
            Image(systemName: kind.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(highlighted ? Color.white : kind.color)
        case .app(let app):
            if let icon = AppIconCache.menuIcon(for: app.bundleID) {
                Image(nsImage: icon)
            } else {
                Image(systemName: "app.dashed")
                    .foregroundStyle(.secondary)
            }
        case .pinboard(let pinboard):
            Image(systemName: "pin.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(highlighted ? Color.white : pinboard.color.color)
        }
    }

    private func title(_ suggestion: FilterSuggestion) -> String {
        switch suggestion {
        case .kind(let kind): kind.title
        case .app(let app): app.name
        case .pinboard(let pinboard): pinboard.name
        }
    }

    private func category(_ suggestion: FilterSuggestion) -> String {
        switch suggestion {
        case .kind: "类型"
        case .app: "应用"
        case .pinboard: "Pinboard"
        }
    }

    /// 已经在筛选条件里了。
    private func isActive(_ suggestion: FilterSuggestion) -> Bool {
        switch suggestion {
        case .kind(let kind): model.filters.kinds.contains(kind)
        case .app(let app): model.filters.sourceApp?.bundleID == app.bundleID
        case .pinboard(let pinboard): model.filters.pinboardIDs.contains(pinboard.id)
        }
    }
}

extension ClipKind {
    var symbolName: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        }
    }
}
