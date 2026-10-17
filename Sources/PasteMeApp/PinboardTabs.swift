import PasteMeCore
import SwiftUI
import UniformTypeIdentifiers

/// 面板左上角的标签：「历史」和各个 Pinboard，最后是新建按钮（#9）。
///
/// 点击或 ⌘← ⌘→ 切换；右键菜单里改名字、颜色和删除，双击也可以改名字；把卡片拖到 Pinboard 的标签上就固定进去。
struct PinboardTabs: View {
    let model: HistoryModel

    var body: some View {
        HStack(spacing: 4) {
            tab(title: "历史", color: nil, selected: model.pinboardID == nil) {
                model.showTab(nil)
            }
            ForEach(model.pinboards) { pinboard in
                PinboardTab(model: model, pinboard: pinboard)
            }
            Button {
                model.onEditPinboard(.create(pinning: nil))
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .focusEffectDisabled()
            .help("新建 Pinboard")
        }
    }

    private func tab(title: String, color: Color?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            TabLabel(title: title, color: color, selected: selected, targeted: false)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

private struct PinboardTab: View {
    let model: HistoryModel
    let pinboard: Pinboard
    @State private var targeted = false

    var body: some View {
        TabLabel(
            title: pinboard.name,
            color: pinboard.color.color,
            selected: model.pinboardID == pinboard.id,
            targeted: targeted
        )
        .onTapGesture(count: 2) { model.onEditPinboard(.rename(pinboard)) }
        .simultaneousGesture(TapGesture().onEnded { model.showTab(pinboard.id) })
        .onDrop(of: [.item], isTargeted: $targeted) { _ in model.dropDraggedCard(on: pinboard) }
        .help("⌘← ⌘→ 切换，把卡片拖到这里固定")
        .contextMenu {
            Button("重命名…") { model.onEditPinboard(.rename(pinboard)) }
            Menu("颜色") {
                ForEach(PinboardColor.allCases, id: \.self) { color in
                    Toggle(color.title, isOn: Binding(
                        get: { pinboard.color == color },
                        set: { _ in model.setColor(color, of: pinboard) }
                    ))
                }
            }
            Divider()
            Button("删除「\(pinboard.name)」…", role: .destructive) { model.onEditPinboard(.delete(pinboard)) }
        }
    }
}

private struct TabLabel: View {
    let title: String
    let color: Color?
    let selected: Bool
    /// 有卡片拖到上面。
    let targeted: Bool

    var body: some View {
        HStack(spacing: 5) {
            if let color {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
            Text(title)
                .lineLimit(1)
        }
        .font(.system(size: 12, weight: selected ? .semibold : .regular))
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(selected ? 0.13 : targeted ? 0.1 : 0)))
        .overlay {
            if targeted {
                Capsule().strokeBorder(color ?? .accentColor, lineWidth: 1.5)
            }
        }
        .contentShape(Capsule())
    }
}
