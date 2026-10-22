import AppKit
import Carbon.HIToolbox
import Observation
import PasteMeCore
import SwiftUI

/// Paste Stack 开启时，对一次按键要做什么。
enum PasteStackKeyAction: Equatable {
    /// 把栈里的下一条写进剪贴板，再让这次 ⌘V 照常送到目标应用。
    case pasteNext
    /// 退出 Paste Stack。按键照常送到目标应用。
    case exit
    case ignore
}

enum PasteStackKeys {
    /// - Parameters:
    ///   - isAutorepeat: 按住不放时系统重复发送的按键。按住 ⌘V 不应一口气取出好几条。
    ///   - isFromPasteMe: PasteMe 从面板粘贴时自己发送的 ⌘V，不从栈里取。
    static func action(keyCode: Int, flags: CGEventFlags, isAutorepeat: Bool, isFromPasteMe: Bool) -> PasteStackKeyAction {
        guard !isFromPasteMe else { return .ignore }
        let modifiers = flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        switch keyCode {
        case kVK_ANSI_V where modifiers == .maskCommand:
            return isAutorepeat ? .ignore : .pasteNext
        case kVK_Escape where modifiers.isEmpty:
            return .exit
        default:
            return .ignore
        }
    }
}

/// 开启、退出 Paste Stack，监听全局 ⌘V，显示栈里条目的浮窗（#6）。
///
/// 时机：用户按下 ⌘V 时，事件监听在按键送到目标应用之前同步回调，这时把下一条写进剪贴板，
/// 目标应用处理这次 ⌘V 时读到的就是它。不需要猜测目标应用什么时候读完剪贴板。
@MainActor
final class PasteStackController {
    let stack: PasteStack
    /// 面板开着时不从栈里取：这时的 ⌘V 是在面板的搜索框里粘贴。
    var isPanelVisible: () -> Bool = { false }
    /// 暂停记录时不能开启：复制的内容不会进栈。
    var isRecordingPaused: () -> Bool = { false }
    /// 开启或退出时调用，用于更新菜单栏图标。
    var onActiveChange: () -> Void = {}

    var showsDuringScreenSharing = false {
        didSet { hud.showsDuringScreenSharing = showsDuringScreenSharing }
    }

    private let store: ClipStore
    private let paster: Paster
    private let toast: Toast
    private let hud = PasteStackHUD()
    private var tap: KeyEventTap?

    init(stack: PasteStack, store: ClipStore, paster: Paster, toast: Toast) {
        self.stack = stack
        self.store = store
        self.paster = paster
        self.toast = toast
        stack.onChange = { [weak self] in self?.stackDidChange() }
        hud.onRemove = { [weak stack] index in stack?.remove(at: index) }
        hud.onClose = { [weak self] in self?.stop() }
    }

    func toggle() {
        stack.isActive ? stop() : start()
    }

    func start() {
        guard !stack.isActive else { return }
        guard !isRecordingPaused() else {
            toast.show("已暂停记录", detail: "恢复记录后才能使用 Paste Stack", symbol: "pause.circle")
            return
        }
        // 监听别的应用里的按键需要辅助功能权限，没有权限时创建不了事件监听。
        guard Accessibility.isTrusted, let tap = KeyEventTap(handler: { [weak self] event in self?.handle(event) }) else {
            toast.show("需要辅助功能权限", detail: "允许后才能使用 Paste Stack", symbol: "lock")
            Accessibility.requestTrust()
            return
        }
        self.tap = tap
        stack.start()
        hud.show(rows: [])
        toast.show("Paste Stack 已开启", detail: "依次复制，再按 ⌘V 按顺序粘贴", symbol: "square.stack.3d.up")
        onActiveChange()
    }

    func stop() {
        guard stack.isActive else { return }
        stack.stop()
        toast.show("已退出 Paste Stack", symbol: "square.stack.3d.up.slash")
    }

    private func stackDidChange() {
        if stack.isActive {
            hud.show(rows: rows())
            return
        }
        // 结束了：手动退出，或最后一条已经取出。在按键回调里结束时，等这次回调返回后再移除监听。
        hud.hide()
        if let tap {
            self.tap = nil
            DispatchQueue.main.async { tap.stop() }
        }
        onActiveChange()
    }

    /// 栈里的条目，按粘贴顺序。已经从历史里删掉的条目不显示。
    private func rows() -> [PasteStackRowItem] {
        let entries = stack.entries
        guard !entries.isEmpty else { return [] }
        let items = (try? store.items(matching: ClipQuery(ids: Array(Set(entries)), limit: entries.count))) ?? []
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return entries.enumerated().compactMap { index, id in
            byID[id].map { PasteStackRowItem(entryIndex: index, item: $0) }
        }
    }

    private func handle(_ event: CGEvent) {
        let action = PasteStackKeys.action(
            keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags,
            isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            isFromPasteMe: event.getIntegerValueField(.eventSourceUserData) == CGEventPasteKeystroke.marker
        )
        switch action {
        case .ignore:
            return
        case .exit:
            stop()
        case .pasteNext:
            guard !isPanelVisible() else { return }
            pasteNext()
        }
    }

    /// 写入下一条。条目已经从历史里删掉时跳过它，取再下一条。
    private func pasteNext() {
        while let id = stack.takeNext() {
            do {
                try paster.copyToPasteboard(id)
                break
            } catch {
                NSLog("PasteMe: Paste Stack 跳过已不存在的条目 \(id)：\(error)")
            }
        }
        if !stack.isActive {
            toast.show("Paste Stack 已粘贴完", symbol: "checkmark.circle")
        }
    }
}

/// 全局键盘事件监听（`CGEventTap`）。只观察按键，不拦截，事件总是原样送到目标应用。
/// 回调在主线程的事件循环里，按键送到目标应用之前同步执行。
@MainActor
final class KeyEventTap {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private let handler: (CGEvent) -> Void

    /// 没有辅助功能权限时创建失败，返回 nil。
    init?(handler: @escaping (CGEvent) -> Void) {
        self.handler = handler
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    let tap = Unmanaged<KeyEventTap>.fromOpaque(userInfo).takeUnretainedValue()
                    MainActor.assumeIsolated { tap.receive(type, event) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }
        self.port = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func stop() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        port = nil
        source = nil
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 系统认为回调太慢或用户输入时会停掉监听，重新打开。
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        case .keyDown:
            handler(event)
        default:
            break
        }
    }

    isolated deinit {
        stop()
    }
}

// MARK: - 浮窗

/// 屏幕右上角的小浮窗，列出栈里的条目，标出下一条。不取得键盘焦点，⌘V 仍然落在目标应用里。
@MainActor
final class PasteStackHUD {
    var onRemove: (Int) -> Void = { _ in }
    var onClose: () -> Void = {}
    var showsDuringScreenSharing = false {
        didSet { panel.sharingType = showsDuringScreenSharing ? .readOnly : .none }
    }

    private let panel = HUDPanel()
    private let state = PasteStackHUDState()
    private lazy var hosting = NSHostingView(rootView: PasteStackView(state: state))

    init() {
        panel.contentView = WindowBackground.make(cornerRadius: 14, material: .hudWindow, content: hosting)
        panel.sharingType = .none
        state.remove = { [weak self] index in self?.onRemove(index) }
        state.close = { [weak self] in self?.onClose() }
    }

    func show(rows: [PasteStackRowItem]) {
        let wasVisible = panel.isVisible
        state.rows = rows
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        // 右上角贴着屏幕边缘。第一次出现时放在鼠标所在的屏幕上，之后保持右上角不动、只改高度。
        let screen = wasVisible ? panel.screen : NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let origin = NSPoint(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 12)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !wasVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private final class HUDPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    // 点浮窗里的按钮也不能抢走目标应用的键盘焦点，否则接下来的 ⌘V 会落到浮窗上。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 浮窗里的一行：条目，以及它在 `PasteStack.entries` 里的位置（拿掉时用）。
struct PasteStackRowItem {
    var entryIndex: Int
    var item: ClipItem
}

@Observable
@MainActor
private final class PasteStackHUDState {
    var rows: [PasteStackRowItem] = []
    @ObservationIgnored var remove: (Int) -> Void = { _ in }
    @ObservationIgnored var close: () -> Void = {}
}

private struct PasteStackView: View {
    let state: PasteStackHUDState

    /// 最多列出几条，其余的只显示条数。
    private static let visibleRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill")
                Text("Paste Stack")
                    .font(.system(size: 13, weight: .semibold))
                if !state.rows.isEmpty {
                    Text("\(state.rows.count) 条")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: state.close) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("退出 Paste Stack")
            }
            if state.rows.isEmpty {
                Text("依次复制要粘贴的内容，再到目标位置按 ⌘V，会按复制的顺序逐条粘贴。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(state.rows.prefix(Self.visibleRows).enumerated()), id: \.offset) { index, row in
                        PasteStackRow(index: index, item: row.item) { state.remove(row.entryIndex) }
                    }
                }
                if state.rows.count > Self.visibleRows {
                    Text("还有 \(state.rows.count - Self.visibleRows) 条")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Text("⌘V 粘贴下一条   esc 或 \(GlobalShortcut.pasteStack.symbol) 退出")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 290)
    }
}

private struct PasteStackRow: View {
    let index: Int
    let item: ClipItem
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .frame(width: 16)
                .foregroundStyle(index == 0 ? Color.white : Color.secondary)
                .padding(.vertical, 2)
                .background(Circle().fill(index == 0 ? Color.accentColor : Color.clear))
            Image(systemName: item.kind.symbol)
                .frame(width: 14)
                .foregroundStyle(.secondary)
            Text(item.stackPreview)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if index == 0 {
                Text("下一条")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .help("从 Paste Stack 拿掉这一条")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(index == 0 ? Color.accentColor.opacity(0.15) : Color.clear))
        .onHover { hovering = $0 }
    }
}

extension ClipKind {
    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        }
    }
}

extension ClipItem {
    /// 浮窗里一行的文字：文本的第一行、链接、图片里识别出的第一行文字、文件名。
    var stackPreview: String {
        switch kind {
        case .text, .link:
            let line = preview?
                .split(whereSeparator: \.isNewline)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return line.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        case .image:
            let line = recognizedText?.split(whereSeparator: \.isNewline).first
            return line.map { "图片：\($0)" } ?? "图片"
        case .file:
            return filePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        }
    }
}
