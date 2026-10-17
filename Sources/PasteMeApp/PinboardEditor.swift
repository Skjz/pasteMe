import AppKit
import Observation
import PasteMeCore
import SwiftUI

/// Pinboard 编辑窗口里正在做的事和填的内容。
@Observable
@MainActor
final class PinboardEditorState {
    enum Mode: Equatable {
        case create(pinning: ClipItem?)
        case rename(Pinboard)
        /// 删除前确认，带着里面有多少个条目。
        case delete(Pinboard, itemCount: Int)
    }

    var mode = Mode.create(pinning: nil)
    var name = ""
    var color = PinboardColor.blue

    var canConfirm: Bool {
        if case .delete = mode { return true }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 新建、重命名、删除 Pinboard 的小窗口，弹在面板左上方的标签上面（#9）。
///
/// 用自己的窗口而不是系统的提示框：系统提示框要激活 PasteMe，目标应用就不在前台了，关掉之后粘贴会失败。
@MainActor
final class PinboardEditorController: NSObject, NSWindowDelegate {
    let window = AuxiliaryPanel(cornerRadius: 12)
    private let state = PinboardEditorState()
    private let model: HistoryModel
    /// 窗口失去键盘焦点。
    var onResignKey: () -> Void = {}
    /// 窗口关掉了，键盘焦点要还给面板。
    var onClose: () -> Void = {}

    init(model: HistoryModel) {
        self.model = model
        super.init()
        window.delegate = self
        window.setContent(PinboardEditorView(
            state: state,
            confirm: { [weak self] in self?.confirm() },
            cancel: { [weak self] in self?.close() }
        ))
    }

    var isVisible: Bool { window.isVisible }

    func open(_ request: PinboardEditRequest, above panelFrame: NSRect) {
        switch request {
        case .create(let item):
            state.mode = .create(pinning: item)
            state.name = ""
            state.color = PinboardColor.next(after: model.pinboards)
        case .rename(let pinboard):
            state.mode = .rename(pinboard)
            state.name = pinboard.name
            state.color = pinboard.color
        case .delete(let pinboard):
            state.mode = .delete(pinboard, itemCount: model.itemCount(of: pinboard))
        }
        let size = NSSize(width: 300, height: window.fittingSize.height)
        window.setFrame(
            NSRect(x: panelFrame.minX + 16, y: panelFrame.maxY + 8, width: size.width, height: size.height),
            display: true
        )
        window.makeKeyAndOrderFront(nil)
        // 内容换了以后高度可能变了。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var frame = self.window.frame
            frame.size.height = self.window.fittingSize.height
            self.window.setFrame(frame, display: true)
        }
    }

    /// ↩ 可能同时触发输入框的提交和默认按钮，只认第一次。
    func confirm() {
        guard isVisible, state.canConfirm else { return }
        switch state.mode {
        case .create(let item):
            if let pinboard = model.createPinboard(named: state.name, color: state.color, pinning: item), item == nil {
                model.showTab(pinboard.id)
            }
        case .rename(let pinboard):
            model.renamePinboard(pinboard, to: state.name, color: state.color)
        case .delete(let pinboard, _):
            model.deletePinboard(pinboard)
        }
        close()
    }

    func close() {
        guard isVisible else { return }
        window.orderOut(nil)
        onClose()
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { onResignKey() }
    }
}

private struct PinboardEditorView: View {
    @Bindable var state: PinboardEditorState
    let confirm: () -> Void
    let cancel: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch state.mode {
            case .create, .rename:
                Text(isCreating ? "新建 Pinboard" : "修改 Pinboard")
                    .font(.headline)
                TextField("名字", text: $state.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(confirm)
                HStack(spacing: 8) {
                    ForEach(PinboardColor.allCases, id: \.self) { color in
                        Circle()
                            .fill(color.color)
                            .frame(width: 18, height: 18)
                            .overlay {
                                if color == state.color {
                                    Circle().strokeBorder(Color.primary.opacity(0.7), lineWidth: 2).padding(-3)
                                }
                            }
                            .contentShape(Circle())
                            .onTapGesture { state.color = color }
                            .help(color.title)
                    }
                }
                .padding(.vertical, 2)
            case .delete(let pinboard, let count):
                Text("删除 Pinboard「\(pinboard.name)」？")
                    .font(.headline)
                Text(count == 0 ? "这个 Pinboard 是空的。" : "里面的 \(count) 个条目还会留在历史里，只是不再固定在这里。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, role: isDeleting ? .destructive : nil, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.canConfirm)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { nameFocused = true }
        .onChange(of: state.mode) { nameFocused = true }
    }

    private var isCreating: Bool {
        if case .create = state.mode { return true }
        return false
    }

    private var isDeleting: Bool {
        if case .delete = state.mode { return true }
        return false
    }

    private var confirmTitle: String {
        switch state.mode {
        case .create: "新建"
        case .rename: "完成"
        case .delete: "删除"
        }
    }
}

extension PinboardColor {
    var color: Color {
        switch self {
        case .red: Color(red: 0.92, green: 0.3, blue: 0.3)
        case .orange: Color(red: 0.95, green: 0.55, blue: 0.2)
        case .yellow: Color(red: 0.93, green: 0.76, blue: 0.15)
        case .green: Color(red: 0.3, green: 0.72, blue: 0.38)
        case .teal: Color(red: 0.2, green: 0.66, blue: 0.7)
        case .blue: Color(red: 0.25, green: 0.5, blue: 0.92)
        case .purple: Color(red: 0.6, green: 0.4, blue: 0.88)
        case .pink: Color(red: 0.93, green: 0.4, blue: 0.65)
        case .gray: Color(red: 0.55, green: 0.57, blue: 0.6)
        }
    }

    var title: String {
        switch self {
        case .red: "红色"
        case .orange: "橙色"
        case .yellow: "黄色"
        case .green: "绿色"
        case .teal: "青色"
        case .blue: "蓝色"
        case .purple: "紫色"
        case .pink: "粉色"
        case .gray: "灰色"
        }
    }
}
