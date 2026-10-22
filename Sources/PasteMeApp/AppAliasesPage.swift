import AppKit
import PasteMeCore
import SwiftUI

/// 设置窗口里「应用别名」这一页的内容：历史里出现过的来源应用、已经能搜到它的名字和用户自己加的别名。
/// 别名在输入时就保存，搜索立即按新的别名找。从卡片的右键菜单打开时定位到那张卡片的来源应用。
@Observable
@MainActor
final class AppAliasesModel {
    struct Row: Identifiable, Equatable {
        let bundleID: String
        /// 记录条目时的应用名。
        let name: String
        /// 应用自己声明的其他名字，例如访达的 "Finder"。不含 `name`。
        let otherNames: [String]

        var id: String { bundleID }
    }

    private(set) var rows: [Row] = []
    /// 页面顶部的查找框：只显示名字或别名包含这段文字的应用。
    var filter = ""
    /// 各应用别名输入框里的文字。保存的是拆分后的别名，这里保留原样，输入到一半的逗号不会被吞掉。
    var aliasTexts: [String: String] = [:]
    /// 要把光标放进哪个应用的别名输入框。`focusRequest` 每次请求加一，同一个应用请求两次也能触发。
    private(set) var focusTarget: String?
    private(set) var focusRequest = 0

    @ObservationIgnored private let appNames: AppNames
    @ObservationIgnored private let settings: PasteMeCore.Settings

    init(appNames: AppNames, settings: PasteMeCore.Settings) {
        self.appNames = appNames
        self.settings = settings
    }

    func reload() {
        appNames.historyChanged()
        rows = appNames.sourceApps().map { app in
            let others = appNames.systemNames(of: app.bundleID).filter {
                $0.caseInsensitiveCompare(app.name) != .orderedSame
            }
            return Row(bundleID: app.bundleID, name: app.name, otherNames: others)
        }
        aliasTexts = settings.appAliases.mapValues(AppAlias.format)
    }

    var visibleRows: [Row] {
        let filter = filter.trimmingCharacters(in: .whitespaces)
        guard !filter.isEmpty else { return rows }
        return rows.filter { row in
            ([row.name] + row.otherNames + [aliasTexts[row.bundleID] ?? ""]).contains {
                $0.range(of: filter, options: [.caseInsensitive, .widthInsensitive]) != nil
            }
        }
    }

    func aliasText(for bundleID: String) -> String {
        aliasTexts[bundleID] ?? ""
    }

    func setAliasText(_ text: String, for bundleID: String) {
        aliasTexts[bundleID] = text
        settings.setAliases(AppAlias.parse(text), for: bundleID)
    }

    func requestFocus(on bundleID: String) {
        focusTarget = bundleID
        focusRequest += 1
    }
}

/// 「应用别名」页：上面是查找框，下面是一组应用，每行是图标、名字和已经能搜到的名字、别名输入框。
struct AppAliasesView: View {
    @Bindable var model: AppAliasesModel
    @FocusState private var focusedRow: String?

    var body: some View {
        VStack(spacing: 0) {
            SearchField(prompt: "查找应用", text: $model.filter)
                .padding(.horizontal, SettingsLayout.margin)
                .padding(.top, 1)
                .padding(.bottom, 14)
            content
        }
    }

    @ViewBuilder private var content: some View {
        if model.rows.isEmpty {
            ContentUnavailableView(
                "还没有应用",
                systemImage: "square.dashed",
                description: Text("历史里还没有来自应用的内容。")
            )
        } else if model.visibleRows.isEmpty {
            ContentUnavailableView(
                "没有找到「\(model.filter.trimmingCharacters(in: .whitespaces))」",
                systemImage: "magnifyingglass",
                description: Text("应用的名字和别名里都没有这段文字。")
            )
        } else {
            ScrollViewReader { proxy in
                SettingsScroll {
                    SettingsGroup(footer: "在面板里搜应用的任何一个名字，都能找到从它复制的内容，`app:` 后面也一样。英文名和中文名已经自动识别，你可以再加自己的别名，多个别名用逗号分隔。") {
                        let first = model.visibleRows.first?.id
                        ForEach(model.visibleRows) { row in
                            if row.id != first {
                                SettingsDivider()
                            }
                            AppAliasRow(row: row, text: binding(for: row.bundleID), focusedRow: $focusedRow)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 9)
                                .id(row.bundleID)
                        }
                    }
                }
                .onAppear { applyFocusRequest(proxy) }
                .onChange(of: model.focusRequest) { applyFocusRequest(proxy) }
            }
        }
    }

    private func binding(for bundleID: String) -> Binding<String> {
        Binding(
            get: { model.aliasText(for: bundleID) },
            set: { model.setAliasText($0, for: bundleID) }
        )
    }

    private func applyFocusRequest(_ proxy: ScrollViewProxy) {
        guard let target = model.focusTarget else { return }
        proxy.scrollTo(target, anchor: .center)
        // 等列表滚到那一行、输入框出现以后再放光标。
        DispatchQueue.main.async { focusedRow = target }
    }
}

private struct AppAliasRow: View {
    static let iconSize: CGFloat = 28
    /// 各行的名字列一样宽，别名输入框才对得齐。太长的名字截断，悬停时显示全部。
    static let nameWidth: CGFloat = 112

    let row: AppAliasesModel.Row
    @Binding var text: String
    var focusedRow: FocusState<String?>.Binding

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                Text(row.otherNames.isEmpty ? row.bundleID : row.otherNames.joined(separator: "、"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: Self.nameWidth, alignment: .leading)
            .help(([row.name] + row.otherNames + [row.bundleID]).joined(separator: "\n"))
            TextField("别名", text: $text, prompt: Text("别名，用逗号分隔"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .focused(focusedRow, equals: row.bundleID)
        }
    }

    @ViewBuilder private var icon: some View {
        if let icon = AppIconCache.icon(for: row.bundleID) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: Self.iconSize, height: Self.iconSize)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 23, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(width: Self.iconSize, height: Self.iconSize)
        }
    }
}

/// 圆角的查找框，左边是放大镜，有文字时右边有清除按钮。
private struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(SettingsLayout.groupFill, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(SettingsLayout.groupBorder)
        }
    }
}
