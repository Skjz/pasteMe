import AppKit
import PasteMeCore

/// 轮询系统剪贴板，发现新内容就交给 `Recorder`。
///
/// macOS 没有剪贴板变化的通知，只能定时检查 `changeCount`；0.5 秒的间隔开销很小。
@MainActor
final class ClipboardMonitor {
    private let recorder: Recorder
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?

    init(recorder: Recorder) {
        self.recorder = recorder
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        // 暂停时连剪贴板的内容都不读。
        guard !recorder.isPaused,
              !PasteboardCodec.isOwnWrite(pasteboard),
              !PasteboardCodec.shouldIgnore(pasteboard),
              let content = PasteboardCodec.read(pasteboard)
        else { return }

        let app = NSWorkspace.shared.frontmostApplication
        let source = ClipSource(bundleID: app?.bundleIdentifier, name: app?.localizedName)
        do {
            try recorder.record(content, from: source)
        } catch {
            NSLog("PasteMe: 保存剪贴板内容失败：\(error)")
        }
    }
}
