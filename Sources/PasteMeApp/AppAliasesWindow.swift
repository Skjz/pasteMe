import AppKit
import PasteMeCore
import SwiftUI

/// 「应用别名」窗口：列出历史里出现过的来源应用和已经能搜到它的名字，编辑用户自己加的别名。
/// 从菜单栏菜单或卡片的右键菜单打开，后者会定位到那张卡片的来源应用。
@MainActor
final class AppAliasesWindow {
    private let model: AppAliasesModel
    private var window: NSWindow?

    init(appNames: AppNames, settings: PasteMeCore.Settings) {
        model = AppAliasesModel(appNames: appNames, settings: settings)
    }

    /// 显示窗口。`bundleID` 不为 nil 时滚动到这个应用，光标放进它的别名输入框。
    func show(focusing bundleID: String? = nil) {
        model.reload()
        model.filter = ""
        let window = self.window ?? makeWindow()
        self.window = window
        // PasteMe 平时不激活，要先激活才能在窗口里打字。
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        if let bundleID { model.requestFocus(on: bundleID) }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "应用别名"
        window.contentView = NSHostingView(rootView: AppAliasesView(model: model))
        window.contentMinSize = NSSize(width: 520, height: 360)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

/// 别名窗口的内容。别名在输入时就保存，搜索立即按新的别名找。
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
    /// 窗口顶部的查找框：只显示名字或别名包含这段文字的应用。
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

struct AppAliasesView: View {
    @Bindable var model: AppAliasesModel
    @FocusState private var focusedRow: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("在面板里搜应用的任何一个名字，都能找到从它复制的内容，`app:` 后面也一样。英文名和中文名已经自动识别，你可以再加自己的别名，多个别名用逗号分隔。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("查找应用", text: $model.filter)
                .textFieldStyle(.roundedBorder)
            if model.rows.isEmpty {
                Text("历史里还没有来自应用的内容。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(model.visibleRows) { row in
                        AppAliasRow(row: row, text: binding(for: row.bundleID), focusedRow: $focusedRow)
                            .id(row.bundleID)
                    }
                    .onAppear { applyFocusRequest(proxy) }
                    .onChange(of: model.focusRequest) { applyFocusRequest(proxy) }
                }
            }
        }
        .padding(16)
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
    let row: AppAliasesModel.Row
    @Binding var text: String
    var focusedRow: FocusState<String?>.Binding

    var body: some View {
        HStack(spacing: 10) {
            if let icon = AppIconCache.icon(for: row.bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 22))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .fontWeight(.medium)
                Text(row.otherNames.isEmpty ? row.bundleID : "也能搜：" + row.otherNames.joined(separator: "、"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            TextField("别名，例如 wx, 绿泡泡", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused(focusedRow, equals: row.bundleID)
        }
        .padding(.vertical, 4)
    }
}
