import AppKit
import PasteMeCore
import SwiftUI

/// 设置窗口：左边侧栏选页，右边是分组的开关。从菜单栏菜单的「设置…」打开，
/// 卡片右键菜单里的「设置别名…」打开「应用别名」页。
///
/// 外观照着 Alcove 的设置窗口：大小固定、不能拉伸；整个窗口是一层透出桌面颜色的材质，侧栏和内容共用它，
/// 中间一条细线；分组是半透明的底加细边；标题栏和带工具栏的窗口一样高，页面标题和红绿灯在同一行。
@MainActor
final class SettingsWindow {
    static let size = NSSize(width: 620, height: 690)

    let model: SettingsModel
    private var window: NSWindow?
    private var activationObserver: NSObjectProtocol?
    private var resignKeyObserver: NSObjectProtocol?
    private var keyMonitor: Any?

    init(model: SettingsModel) {
        self.model = model
    }

    /// 打开窗口。`page` 为 nil 时停在上次看的那一页。
    func show(_ page: SettingsModel.Page? = nil) {
        model.reload()
        model.aliases.filter = ""
        if let page { model.page = page }
        let window = self.window ?? makeWindow()
        self.window = window
        // PasteMe 平时不激活，要先激活才能在窗口里打字。从菜单栏菜单打开时，`NSApp.activate()` 的请求
        // 偶尔不被系统执行，前台还是原来的应用，窗口被挡在后面（#62）。先把窗口放到最上面，激活失败时至少看得见；
        // 激活用和更新窗口一样的 `activate(ignoringOtherApps:)`。
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// 打开「应用别名」页，滚动到这个应用，光标放进它的别名输入框。
    func showAliases(focusing bundleID: String) {
        show(.aliases)
        model.aliases.requestFocus(on: bundleID)
    }

    func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "PasteMe 设置"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // 空的工具栏只为了让标题栏和 Alcove 一样高（`SettingsLayout.titlebarHeight`），红绿灯离窗口边远一些。
        window.toolbar = NSToolbar(identifier: "Settings")
        window.toolbarStyle = .unified
        let content = NSHostingController(rootView: SettingsView(model: model))
        // 窗口大小只由 `size` 决定，不让 SwiftUI 按各页内容的大小给窗口加约束。
        content.sizingOptions = []
        window.contentViewController = content
        window.setContentSize(Self.size)
        window.isReleasedWhenClosed = false
        window.center()
        // 去系统设置里打开辅助功能权限、登录项以后回来，页面上的状态跟着更新。
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refreshSystemState() }
        }
        // 录制全局快捷键时（#50）窗口里的按键都交给录制：本地监视器在菜单的快捷键之前收到，⌘W、⌘Q 也能录。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            let recorded = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.model.recordingShortcut != nil, event.window === window else { return false }
                self.model.recordKey(KeyCombo(keyCode: event.keyCode, flags: event.modifierFlags))
                return true
            }
            return recorded ? nil : event
        }
        // 切到别的应用、关掉窗口，录了一半的快捷键算取消。
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.cancelRecording() }
        }
        return window
    }
}

/// 尺寸照着 Alcove 的设置窗口量的。
enum SettingsLayout {
    static let sidebarWidth: CGFloat = 224
    /// 带工具栏的标题栏高度，红绿灯和页面标题在这一条里居中。
    static let titlebarHeight: CGFloat = 52
    /// 侧栏的行离侧栏两边的距离。
    static let sidebarPadding: CGFloat = 12
    /// 分组离内容区两边的距离。
    static let margin: CGFloat = 18
    static let groupCornerRadius: CGFloat = 10
    /// 分组的底、侧栏选中行的底和分隔线：在深色和浅色的材质上都是一层很淡的前景色。
    static let groupFill = Color.primary.opacity(0.05)
    static let groupBorder = Color.primary.opacity(0.08)
    static let selectionFill = Color.primary.opacity(0.06)
    static let separator = Color.primary.opacity(0.08)
}

extension SettingsModel.Page {
    var title: String {
        switch self {
        case .general: "通用"
        case .panel: "面板"
        case .linkPreview: "链接预览"
        case .history: "历史"
        case .aliases: "应用别名"
        case .about: "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .panel: "dock.rectangle"
        case .linkPreview: "link"
        case .history: "clock.arrow.circlepath"
        case .aliases: "tag.fill"
        case .about: "info"
        }
    }

    var tint: Color {
        switch self {
        case .general, .about: .gray
        case .panel: .blue
        case .linkPreview: .indigo
        case .history: .orange
        case .aliases: .pink
        }
    }
}

/// 侧栏自己画，不用 `NavigationSplitView`：它的侧栏可以收起、会在标题栏里放收起按钮，

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: SettingsLayout.sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .top)
            Rectangle()
                .fill(SettingsLayout.separator)
                .frame(width: 1)
            detail
        }
        .ignoresSafeArea(edges: .top)
        .background(WindowMaterial().ignoresSafeArea())
    }

    /// 侧栏自己画，不用 `NavigationSplitView`：它的侧栏可以收起、会在标题栏里放收起按钮，
    /// macOS 26 上还是浮在内容上的玻璃面板。
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarRow(page: .general, selection: $model.page)
            SidebarHeader(title: "功能")
            SidebarRow(page: .panel, selection: $model.page)
            SidebarRow(page: .linkPreview, selection: $model.page)
            SidebarRow(page: .history, selection: $model.page)
            SidebarHeader(title: "搜索")
            SidebarRow(page: .aliases, selection: $model.page)
            SidebarHeader(title: "PasteMe")
            SidebarRow(page: .about, selection: $model.page)
        }
        .padding(.horizontal, SettingsLayout.sidebarPadding)
        .padding(.top, SettingsLayout.titlebarHeight + 1)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 在标题栏里，和红绿灯在同一行。
            HStack(spacing: 8) {
                SettingsIcon(page: model.page, size: 22)
                Text(model.page.title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, SettingsLayout.margin)
            .frame(height: SettingsLayout.titlebarHeight)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .toggleStyle(.switch)
    }

    @ViewBuilder private var page: some View {
        switch model.page {
        case .general: GeneralPage(model: model)
        case .panel: PanelPage(model: model)
        case .linkPreview: LinkPreviewPage(model: model)
        case .history: HistoryPage(model: model)
        case .aliases: AppAliasesView(model: model.aliases)
        case .about: AboutPage(model: model)
        }
    }
}

private struct SidebarRow: View {
    let page: SettingsModel.Page
    @Binding var selection: SettingsModel.Page

    var body: some View {
        Button {
            selection = page
        } label: {
            HStack(spacing: 8) {
                SettingsIcon(page: page, size: 22)
                Text(page.title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(
                selection == page ? SettingsLayout.selectionFill : .clear,
                in: .rect(cornerRadius: SettingsLayout.groupCornerRadius)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == page ? .isSelected : [])
    }
}

private struct SidebarHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
            .padding(.top, 20)
            .padding(.bottom, 6)
    }
}

/// 整个窗口的底：透出桌面颜色的材质，窗口不在前台时也一样（和 Alcove 一致）。
private struct WindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// 侧栏和页面标题前的图标：系统设置那样的彩色圆角方块，中间是白色的符号。
struct SettingsIcon: View {
    let page: SettingsModel.Page
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(page.tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: page.symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

// MARK: - 分组

/// 一页设置：可以滚动，分组之间留出间距。
struct SettingsScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .padding(.horizontal, SettingsLayout.margin)
            .padding(.top, 1)
            .padding(.bottom, SettingsLayout.margin)
        }
    }
}

/// 一组设置：半透明的圆角底和细边，上面可以有小标题，下面可以有说明。行之间的分隔线用 `SettingsDivider`。
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 7)
            }
            VStack(spacing: 0) {
                content
            }
            .background(SettingsLayout.groupFill, in: .rect(cornerRadius: SettingsLayout.groupCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: SettingsLayout.groupCornerRadius)
                    .strokeBorder(SettingsLayout.groupBorder)
            }
            if let footer {
                Text(footer)
                    .settingsNote()
                    .padding(.horizontal, 7)
            }
        }
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(SettingsLayout.separator)
            .frame(height: 1)
    }
}

/// 分组里的一行：左边标题和可选的说明，右边是开关、按钮或菜单。
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    /// 说明是一条要用户注意的问题（例如录下的快捷键不能用），用红色。
    var detailIsWarning = false
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(detailIsWarning ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 11)
        .frame(minHeight: 42)
    }
}

extension View {
    /// 分组上下的说明文字。
    func settingsNote() -> some View {
        font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 各页

private struct GeneralPage: View {
    let model: SettingsModel

    var body: some View {
        SettingsScroll {
            SettingsGroup {
                SettingsRow(title: "登录时启动") {
                    Toggle("登录时启动", isOn: Binding(get: { model.launchesAtLogin }, set: model.setLaunchesAtLogin))
                        .labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "复制时播放提示音", detail: "每记下一次复制响一声。打开时先响一次。") {
                    Toggle("复制时播放提示音", isOn: Binding(get: { model.playsSoundOnRecord }, set: model.setPlaysSoundOnRecord))
                        .labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "辅助功能权限", detail: "粘贴到其他应用、Paste Stack 都要用到。") {
                    if model.accessibilityTrusted {
                        Label("已开启", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("打开系统设置") { model.openAccessibilitySettings() }
                    }
                }
            }
            SettingsGroup(title: "全局快捷键", footer: "点一下快捷键再按下新的组合。录制时按 esc 取消，按 ⌫ 清除；清除后可以在菜单栏菜单里使用这项功能。") {
                ForEach(GlobalAction.allCases, id: \.self) { action in
                    if action != GlobalAction.allCases.first {
                        SettingsDivider()
                    }
                    let note = model.shortcutNotes[action]
                    SettingsRow(title: action.title, detail: note?.text, detailIsWarning: note?.isProblem == true) {
                        ShortcutRecorder(action: action, model: model)
                    }
                }
            }
        }
    }
}

/// 一个全局快捷键（#50）：按钮上是现在的组合，点了开始录制，按键由 `SettingsWindow` 的事件监视器交给
/// `SettingsModel.recordKey`。和默认值不同时旁边有「恢复默认」。
private struct ShortcutRecorder: View {
    let action: GlobalAction
    let model: SettingsModel

    private var recording: Bool { model.recordingShortcut == action }

    var body: some View {
        HStack(spacing: 8) {
            if !recording, model.shortcuts[action] != action.defaultCombo {
                Button("恢复默认") { model.resetShortcut(action) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .fixedSize()
            }
            Button { model.toggleRecording(action) } label: {
                Text(recording ? "请按下快捷键" : model.shortcuts[action]?.symbol ?? "未设置")
                    .foregroundStyle(recording ? Color.accentColor : model.shortcuts[action] == nil ? .secondary : .primary)
                    .frame(minWidth: 92)
            }
            .accessibilityLabel("\(action.title)的快捷键")
        }
        .fixedSize()
    }
}

private struct PanelPage: View {
    let model: SettingsModel

    var body: some View {
        SettingsScroll {
            SettingsGroup(title: "光标样式") {
                HStack(spacing: 10) {
                    ForEach(CursorStyle.allCases, id: \.self) { style in
                        CursorStyleTile(style: style, selected: model.cursorStyle == style) {
                            model.setCursorStyle(style)
                        }
                    }
                }
                .padding(11)
            }
            SettingsGroup {
                SettingsRow(
                    title: "共享屏幕时显示面板",
                    detail: "默认在共享屏幕、录屏和截图里隐藏面板和预览窗口，自己的屏幕上照常显示。录教程时再打开。"
                ) {
                    Toggle("共享屏幕时显示面板", isOn: Binding(get: { model.showDuringScreenSharing }, set: model.setShowDuringScreenSharing))
                        .labelsHidden()
                }
            }
            SettingsGroup(title: "粘贴") {
                SettingsRow(
                    title: "图片以文件粘贴",
                    detail: "粘贴图片时附带一个 PNG 文件，粘贴到访达里会变成文件。有的聊天软件会把它当附件发出去。"
                ) {
                    Toggle("图片以文件粘贴", isOn: Binding(get: { model.pasteImagesAsFiles }, set: model.setPasteImagesAsFiles))
                        .labelsHidden()
                }
            }
            SettingsGroup(title: "打开", footer: "选中卡片按 ⌘O 时用这里选的应用打开；右键菜单的「打开方式」里可以临时换一个。链接总是用默认的浏览器打开。") {
                SettingsRow(title: "文件的打开方式", detail: "选终端时打开文件所在的文件夹。") {
                    OpenAppPicker(title: "文件的打开方式", forFolders: false, model: model)
                }
                SettingsDivider()
                SettingsRow(title: "文件夹的打开方式") {
                    OpenAppPicker(title: "文件夹的打开方式", forFolders: true, model: model)
                }
            }
        }
    }
}

/// 文件或文件夹的打开方式（#51）：系统默认的方式、编辑器、终端三组，没装的应用是灰的。
private struct OpenAppPicker: View {
    let title: String
    let forFolders: Bool
    let model: SettingsModel

    var body: some View {
        let selection = Binding(
            get: { forFolders ? model.folderApp : model.fileApp },
            set: { forFolders ? model.setFolderApp($0) : model.setFileApp($0) }
        )
        Picker(title, selection: selection) {
            option(.systemDefault)
            Divider()
            ForEach(OpenApp.allCases.filter { $0 != .systemDefault && !$0.isTerminal }, id: \.self, content: option)
            Divider()
            ForEach(OpenApp.allCases.filter(\.isTerminal), id: \.self, content: option)
        }
        .labelsHidden()
        .fixedSize()
    }

    private func option(_ app: OpenApp) -> some View {
        let available = app.isAvailable(isInstalled: model.isInstalled)
        let name = app.title(forFolders: forFolders)
        return Text(available ? name : "\(name)（没有安装）")
            .tag(app)
            .disabled(!available)
    }
}

/// 光标样式的选项：一张小卡片外面套着这种光标，下面是名字。选中的外面有一圈描边，和 Alcove 的选项方块一样。
private struct CursorStyleTile: View {
    let style: CursorStyle
    let selected: Bool
    let choose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.background)
                    .overlay(alignment: .top) {
                        UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12)
                            .fill(Color.accentColor)
                            .frame(height: 14)
                    }
                    .frame(width: 80, height: 52)
                    .padding(SelectionCursor.outset)
                    .overlay {
                        SelectionCursor(style: style, color: .accentColor, cardsFocused: true, animating: !reduceMotion)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(SettingsLayout.groupFill, in: .rect(cornerRadius: SettingsLayout.groupCornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: SettingsLayout.groupCornerRadius)
                            .strokeBorder(SettingsLayout.groupBorder)
                    }
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: SettingsLayout.groupCornerRadius + 3)
                            .strokeBorder(selected ? Color.primary.opacity(0.35) : .clear, lineWidth: 3)
                    }
                Text(style.title)
                    .fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct LinkPreviewPage: View {
    let model: SettingsModel

    var body: some View {
        SettingsScroll {
            SettingsGroup(footer: "这里管的是复制链接时在后台获取的预览。本机和内网的地址都不会请求。打开以后，以前复制的链接不会补做，再复制一次就会获取。按空格预览链接时会打开网页、执行网页里的脚本，不受这里的设置影响。") {
                ForEach(LinkPreviewMode.allCases, id: \.self) { mode in
                    if mode != LinkPreviewMode.allCases.first {
                        SettingsDivider()
                    }
                    option(mode)
                }
            }
        }
    }

    private func option(_ mode: LinkPreviewMode) -> some View {
        let selected = model.linkPreviewMode == mode
        return Button {
            model.setLinkPreviewMode(mode)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title)
                    Text(mode.explanation)
                        .settingsNote()
                }
                Spacer(minLength: 0)
            }
            .padding(11)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct HistoryPage: View {
    let model: SettingsModel

    var body: some View {
        SettingsScroll {
            SettingsGroup {
                SettingsRow(
                    title: "自动清除历史",
                    detail: "超过这段时间没有再复制或粘贴过的条目会被删除，固定在 Pinboard 里的条目保留。每小时检查一次。"
                ) {
                    Picker("自动清除历史", selection: Binding(get: { model.historyRetention }, set: model.chooseRetention)) {
                        ForEach(HistoryRetention.allCases, id: \.self) { retention in
                            Text(retention.title).tag(retention)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                SettingsDivider()
                SettingsRow(title: "清空历史", detail: "删除所有不在 Pinboard 里的条目。") {
                    Button("清空…", role: .destructive) { model.requestClearHistory() }
                }
            }
        }
        .alert(
            retentionTitle,
            isPresented: Binding(get: { model.pendingRetention != nil }, set: { if !$0 { model.cancelRetention() } }),
            presenting: model.pendingRetention
        ) { _ in
            Button("清除", role: .destructive) { model.confirmRetention() }
            Button("取消", role: .cancel) { model.cancelRetention() }
        } message: { pending in
            let days = pending.retention.days ?? 0
            Text("现在会删除 \(pending.count) 个超过 \(days) 天没用过的条目，固定在 Pinboard 里的条目保留。之后每小时检查一次，超过 \(days) 天没有再复制或粘贴过的条目都会删除。此操作无法撤销。")
        }
        .alert(
            "清空剪贴板历史？",
            isPresented: Binding(get: { model.pendingClear != nil }, set: { if !$0 { model.cancelClearHistory() } }),
            presenting: model.pendingClear
        ) { _ in
            Button("清空", role: .destructive) { model.confirmClearHistory() }
            Button("取消", role: .cancel) { model.cancelClearHistory() }
        } message: { pinned in
            Text(pinned == 0
                ? "所有条目都会被删除。此操作无法撤销。"
                : "固定在 Pinboard 里的 \(pinned) 个条目会保留，其他条目都会被删除。此操作无法撤销。")
        }
    }

    private var retentionTitle: String {
        "清除 \(model.pendingRetention?.retention.days ?? 0) 天前的历史？"
    }
}

private struct AboutPage: View {
    let model: SettingsModel

    private var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "开发版本" }
        return "版本 \(short)（\(info?["CFBundleVersion"] as? String ?? "?")）"
    }

    var body: some View {
        SettingsScroll {
            SettingsGroup {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 88, height: 88)
                    Text("PasteMe")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(version)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
            SettingsGroup {
                SettingsRow(title: "自动检查更新", detail: "每天向 GitHub 查一次有没有新版本，不发送任何内容。有新版本时在菜单栏菜单里更新。") {
                    Toggle("自动检查更新", isOn: Binding(get: { model.checksForUpdates }, set: model.setChecksForUpdates))
                        .labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "检查更新") {
                    Button("立即检查") { model.checkForUpdates() }
                }
            }
            SettingsGroup {
                AboutLink(title: "项目主页", value: "github.com/Skjz/pasteMe", url: "https://github.com/Skjz/pasteMe")
                SettingsDivider()
                AboutLink(title: "反馈问题", value: "GitHub Issues", url: "https://github.com/Skjz/pasteMe/issues")
            }
        }
    }
}

private struct AboutLink: View {
    let title: String
    let value: String
    let url: String

    var body: some View {
        Link(destination: URL(string: url)!) {
            SettingsRow(title: title) {
                HStack(spacing: 4) {
                    Text(value)
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

extension HistoryRetention {
    var title: String {
        switch self {
        case .never: "永不"
        case .week: "7 天前的"
        case .month: "30 天前的"
        case .quarter: "90 天前的"
        case .year: "1 年前的"
        }
    }
}

extension LinkPreviewMode {
    var title: String {
        switch self {
        case .off: "关闭"
        case .siteIcon: "只取网站图标"
        case .full: "完整预览"
        }
    }

    var explanation: String {
        switch self {
        case .off:
            "不发出任何请求，链接卡片只显示网址。"
        case .siteIcon:
            "复制网页链接后，只打开这个网站的首页，取得网站图标显示在卡片上。你复制的网址本身不会被打开，"
                + "所以不会让一次性的登录链接、重置密码的链接失效。对方网站会看到有人访问了它的首页。"
        case .full:
            "复制网页链接后打开这个网址，取得网页标题、预览图和网站图标，搜索时也能搜到网页标题。"
                + "只下载网页本身，不执行网页里的脚本，也不带你的登录信息（Cookie）。"
                + "看起来像一次性的链接（网址里有 token、reset、verify 这类词，或者一长串随机字符）只取网站图标，"
                + "但仍有极少数认不出来，被打开一次就可能失效；在意的话请选「只取网站图标」。"
        }
    }
}
