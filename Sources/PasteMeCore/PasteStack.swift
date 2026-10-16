import Foundation

/// Paste Stack：开启后依次复制的条目按复制顺序排好，之后每次粘贴取出最前面的一条，取完即结束（#6）。
///
/// 这里只管顺序和开关；监听 ⌘V、把条目写进剪贴板由应用层的 `PasteStackController` 负责。
@MainActor
public final class PasteStack {
    public private(set) var isActive = false
    /// 等待粘贴的条目 id，下一条在最前。同一条目复制了两次就出现两次。
    public private(set) var entries: [Int64] = []
    /// 开关或条目变化时调用。
    public var onChange: () -> Void = {}

    public init() {}

    /// 开启。之前留下的条目清空。
    public func start() {
        isActive = true
        entries = []
        onChange()
    }

    public func stop() {
        guard isActive else { return }
        isActive = false
        entries = []
        onChange()
    }

    /// 加入刚复制的条目。没有开启时什么都不做。
    public func push(_ id: Int64) {
        guard isActive else { return }
        entries.append(id)
        onChange()
    }

    /// 取出下一条要粘贴的条目。取出的是最后一条时 Paste Stack 随之结束。没有条目时返回 nil。
    public func takeNext() -> Int64? {
        guard isActive, !entries.isEmpty else { return nil }
        let id = entries.removeFirst()
        if entries.isEmpty { isActive = false }
        onChange()
        return id
    }

    /// 从栈里拿掉第 `index` 条，不粘贴。Paste Stack 不会因此结束。
    public func remove(at index: Int) {
        guard entries.indices.contains(index) else { return }
        entries.remove(at: index)
        onChange()
    }
}
