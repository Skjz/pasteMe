import AppKit
import PasteMeCore
import SwiftUI

/// 安装更新时的小窗口：下载的进度条和大小，可以取消；下载完是「正在安装」，不能取消。
/// 换好应用以后 PasteMe 退出，窗口跟着消失；失败或取消时 `Updater` 关掉它。
@MainActor
final class UpdateWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let updater: Updater

    init(updater: Updater, version: AppVersion) {
        self.updater = updater
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        super.init()
        window.title = "更新 PasteMe"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: UpdateProgressView(updater: updater, version: version))
        window.setContentSize(window.contentView!.fittingSize)
        window.delegate = self
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.delegate = nil
        window.close()
    }

    /// 关窗口等于取消，正在换应用时不让关。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard case .downloading = updater.step else { return false }
        updater.cancelInstall()
        return false
    }
}

struct UpdateProgressView: View {
    let updater: Updater
    let version: AppVersion

    var body: some View {
        UpdateProgressContent(step: updater.step, version: version) { updater.cancelInstall() }
    }
}

/// 窗口的内容，只看现在是哪一步。
///
/// 窗口的大小在打开时按第一步（正在下载）定下来，之后不再变；说明文字固定留两行的高度，
/// 「正在安装」「正在检查」那两句较长的说明换行也放得下，不会被截成「…」。
struct UpdateProgressContent: View {
    let step: Updater.InstallStep?
    let version: AppVersion
    let onCancel: () -> Void

    static let width: CGFloat = 400
    static let padding: CGFloat = 20
    static let iconSize: CGFloat = 56
    static let spacing: CGFloat = 16
    /// 标题、进度条和说明文字可用的宽度。
    static let textWidth = width - padding * 2 - iconSize - spacing

    /// 下载完以后不能取消。
    private var isInstalling: Bool { step == .installing || step == .checking }

    var body: some View {
        HStack(alignment: .top, spacing: Self.spacing) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: Self.iconSize, height: Self.iconSize)
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.title(for: step, version: version))
                    .font(.headline)
                progress
                Self.detail(Self.detailText(for: step))
                HStack {
                    Spacer()
                    Button("取消", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                        .disabled(isInstalling)
                }
                .padding(.top, 4)
            }
        }
        .padding(Self.padding)
        .frame(width: Self.width)
    }

    static func title(for step: Updater.InstallStep?, version: AppVersion) -> String {
        switch step {
        case .checking: "正在检查 PasteMe \(version)"
        case .installing: "正在安装 PasteMe \(version)"
        case .downloading, nil: "正在下载 PasteMe \(version)"
        }
    }

    static func detailText(for step: Updater.InstallStep?) -> String {
        switch step {
        case .downloading(let received, let total?) where total > 0: "\(size(received)) / \(size(total))"
        case .downloading(let received, _): size(received)
        case .checking: "核对安装包里的应用，完成后放进「下载」文件夹并打开"
        case .installing, nil: "检查安装包并替换应用，完成后 PasteMe 会重新打开"
        }
    }

    @ViewBuilder private var progress: some View {
        if case .downloading(let received, let total?) = step, total > 0 {
            ProgressView(value: Double(min(received, total)), total: Double(total))
        } else {
            ProgressView().progressViewStyle(.linear)
        }
    }

    /// 说明文字：最多两行，一行时也占两行的高度。
    static func detail(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(2, reservesSpace: true)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
