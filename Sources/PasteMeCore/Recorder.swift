import Foundation

/// 把一次复制记录进历史，并管理暂停。
///
/// 剪贴板轮询（`ClipboardMonitor`）只负责发现新内容和来源应用；记不记录、记录之后要通知谁，都在这里决定。
@MainActor
public final class Recorder {
    /// 暂停到什么时候。`Date.distantFuture` 表示直到手动恢复，nil 表示没有暂停。
    /// 只在内存里，应用重启后总是从记录状态开始，避免用户忘了已经暂停、一直没有记录。
    public private(set) var pausedUntil: Date?
    /// 暂停或恢复时调用，包括定时暂停到时自动恢复。
    public var onPauseChange: () -> Void = {}
    /// 记下一个条目之后调用，参数是条目的 id。再次复制已有内容时也会调用。
    public var onRecord: (Int64) -> Void = { _ in }

    private let store: ClipStore
    private let now: () -> Date
    private var resumeTimer: Timer?

    /// `now` 用于测试时控制时间。
    public init(store: ClipStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    public var isPaused: Bool {
        guard let pausedUntil else { return false }
        return now() < pausedUntil
    }

    /// 暂停记录，到 `date` 时自动恢复。不传时一直暂停到调用 `resume()`。
    public func pause(until date: Date = .distantFuture) {
        pausedUntil = date
        resumeTimer?.invalidate()
        resumeTimer = nil
        if date != .distantFuture {
            let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            }
            RunLoop.main.add(timer, forMode: .common)
            resumeTimer = timer
        }
        onPauseChange()
    }

    public func resume() {
        resumeTimer?.invalidate()
        resumeTimer = nil
        guard pausedUntil != nil else { return }
        pausedUntil = nil
        onPauseChange()
    }

    /// 记录一次复制，返回条目的 id。暂停期间不记录，返回 nil。
    @discardableResult
    public func record(_ content: ClipContent, from source: ClipSource?) throws -> Int64? {
        if let pausedUntil, now() >= pausedUntil {
            // 定时器还没来得及触发，暂停时间已经过了。
            resume()
        }
        guard !isPaused else { return nil }
        let id = try store.insert(content, source: source, at: now())
        onRecord(id)
        return id
    }
}
