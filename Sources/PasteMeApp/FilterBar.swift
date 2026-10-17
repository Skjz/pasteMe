import AppKit
import PasteMeCore
import SwiftUI

/// 搜索框右边的筛选控件：四个类型按钮、来源应用菜单、时间菜单，有 Pinboard 时加一个 Pinboard 菜单，
/// 有筛选时再加一个清除按钮。
struct FilterBar: View {
    @Bindable var model: HistoryModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ClipKind.allCases, id: \.self) { kind in
                KindToggle(kind: kind, isOn: model.filters.kinds.contains(kind)) {
                    model.toggleKind(kind)
                }
            }
            Divider().frame(height: 14).padding(.horizontal, 2)
            FilterMenuButton(
                title: model.filters.sourceApp?.name ?? "所有应用",
                icon: AppIconCache.icon(for: model.filters.sourceApp?.bundleID),
                isActive: model.filters.sourceApp != nil,
                makeMenu: makeAppMenu
            )
            FilterMenuButton(
                title: model.filters.timeRange == .all ? "所有时间" : model.filters.timeRange.title,
                icon: nil,
                isActive: model.filters.timeRange != .all,
                makeMenu: makeTimeMenu
            )
            if !model.pinboards.isEmpty {
                FilterMenuButton(
                    title: pinboardTitle,
                    icon: nil,
                    isActive: !model.filters.pinboardIDs.isEmpty,
                    makeMenu: makePinboardMenu
                )
            }
            if model.filters.isActive {
                Button {
                    model.filters = PanelFilters()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("清除筛选")
            }
        }
    }

    private func makeAppMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("所有应用", checked: model.filters.sourceApp == nil) {
            model.filters.sourceApp = nil
        })
        let apps = model.sourceApps()
        if !apps.isEmpty { menu.addItem(.separator()) }
        for app in apps {
            let item = ClosureMenuItem(app.name, checked: model.filters.sourceApp?.bundleID == app.bundleID) {
                model.filters.sourceApp = app
            }
            item.image = AppIconCache.menuIcon(for: app.bundleID)
            menu.addItem(item)
        }
        return menu
    }

    /// 选了的 Pinboard 的名字，没选时是「所有 Pinboard」。
    private var pinboardTitle: String {
        let names = model.pinboards.filter { model.filters.pinboardIDs.contains($0.id) }.map(\.name)
        return names.isEmpty ? "不限 Pinboard" : names.joined(separator: "、")
    }

    /// 可以选几个 Pinboard，看固定在其中任意一个里的条目。
    private func makePinboardMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("不限 Pinboard", checked: model.filters.pinboardIDs.isEmpty) {
            model.filters.pinboardIDs = []
        })
        menu.addItem(.separator())
        for pinboard in model.pinboards {
            let selected = model.filters.pinboardIDs.contains(pinboard.id)
            menu.addItem(ClosureMenuItem(pinboard.name, checked: selected) {
                if selected {
                    model.filters.pinboardIDs.remove(pinboard.id)
                } else {
                    model.filters.pinboardIDs.insert(pinboard.id)
                }
            })
        }
        return menu
    }

    private func makeTimeMenu() -> NSMenu {
        let menu = NSMenu()
        for range in TimeRange.allCases {
            let title = range == .all ? "所有时间" : range.title
            menu.addItem(ClosureMenuItem(title, checked: model.filters.timeRange == range) {
                model.filters.timeRange = range
            })
            if range == .all { menu.addItem(.separator()) }
        }
        return menu
    }
}

/// 按类型筛选的小按钮，选中时填上类型的颜色。
private struct KindToggle: View {
    let kind: ClipKind
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(kind.title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .background(Capsule().fill(isOn ? kind.color : Color.primary.opacity(0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(isOn ? "不再只看\(kind.title)" : "只看\(kind.title)")
    }
}

/// 点一下在鼠标处弹出菜单的按钮。菜单用 AppKit 的 `NSMenu`，点开时才生成，这样来源应用列表在需要时才查询。
private struct FilterMenuButton: View {
    let title: String
    let icon: NSImage?
    let isActive: Bool
    let makeMenu: () -> NSMenu

    var body: some View {
        Button {
            makeMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        } label: {
            HStack(spacing: 4) {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 14, height: 14)
                }
                Text(title)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .background(Capsule().fill(Color.primary.opacity(isActive ? 0.14 : 0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

/// 点击时执行一个闭包的菜单项。
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func run() {
        handler()
    }
}

extension TimeRange {
    var title: String {
        switch self {
        case .all: "全部"
        case .today: "今天"
        case .yesterday: "昨天"
        case .last7Days: "最近 7 天"
        case .last30Days: "最近 30 天"
        }
    }
}
