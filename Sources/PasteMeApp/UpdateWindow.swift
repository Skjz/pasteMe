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

    /// 下载完以后不能取消。
    private var isInstalling: Bool { updater.step == .installing || updater.step == .checking }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                progress
                HStack {
                    Spacer()
                    Button("取消") { updater.cancelInstall() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isInstalling)
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private var title: String {
        switch updater.step {
        case .checking: "正在检查 PasteMe \(version)"
        case .installing: "正在安装 PasteMe \(version)"
        case .downloading, nil: "正在下载 PasteMe \(version)"
        }
    }

    @ViewBuilder private var progress: some View {
        switch updater.step {
        case .downloading(let received, let total?) where total > 0:
            ProgressView(value: Double(min(received, total)), total: Double(total))
            detail("\(Self.size(received)) / \(Self.size(total))")
        case .downloading(let received, _):
            ProgressView().progressViewStyle(.linear)
            detail(Self.size(received))
        case .checking:
            ProgressView().progressViewStyle(.linear)
            detail("核对安装包里的应用，完成后放进「下载」文件夹并打开")
        case .installing, nil:
            ProgressView().progressViewStyle(.linear)
            detail("检查安装包并替换应用，完成后 PasteMe 会重新打开")
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
