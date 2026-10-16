import AppKit
import PasteMeCore

/// 轮询系统剪贴板，发现新内容就存入历史。
///
/// macOS 没有剪贴板变化的通知，只能定时检查 `changeCount`；0.5 秒的间隔开销很小。
@MainActor
final class ClipboardMonitor {
    var isPaused = false

    private let store: ClipStore
    private let pasteboard = NSPasteboard.general
    private let onChange: () -> Void
    private var lastChangeCount: Int
    private var timer: Timer?

    init(store: ClipStore, onChange: @escaping () -> Void) {
        self.store = store
        self.onChange = onChange
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

        guard !isPaused,
              !PasteboardCodec.isOwnWrite(pasteboard),
              !PasteboardCodec.shouldIgnore(pasteboard),
              let content = PasteboardCodec.read(pasteboard)
        else { return }

        let app = NSWorkspace.shared.frontmostApplication
        let source = ClipSource(bundleID: app?.bundleIdentifier, name: app?.localizedName)
        do {
            try store.insert(content, source: source)
            onChange()
        } catch {
            NSLog("PasteMe: 保存剪贴板内容失败：\(error)")
        }
    }
}
