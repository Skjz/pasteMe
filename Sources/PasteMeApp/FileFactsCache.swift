import Foundation
import Observation
import PasteMeCore

/// 文件卡片上的文件信息（`FileFacts`）。读文件系统可能很慢（大文件夹、网络磁盘），所以在后台读，读到后卡片重画。
///
/// 卡片第一次显示某个路径时请求（`facts(for:)` 先返回 nil），同一轮画卡片时请求的路径一起交给后台、一起写回，
/// 卡片只多画一次。读到的一直留着；每次呼出面板以后 `refresh()` 在后台重读一遍，只写回变了的，
/// 文件后来被删掉、改了大小，下次打开面板时卡片也跟着变，不会每次打开都先空着再填上。
@MainActor
@Observable
final class FileFactsCache {
    static let shared = FileFactsCache()

    private(set) var known: [String: FileFacts] = [:]
    /// 已经交给后台、还没写回的路径。
    @ObservationIgnored private var requested: Set<String> = []
    /// 这一轮请求的、还没交给后台的路径。
    @ObservationIgnored private var queued: [String] = []
    @ObservationIgnored private let read: @Sendable (String) -> FileFacts
    /// 正在读的那一轮，测试等它读完。
    @ObservationIgnored private(set) var reading: Task<Void, Never>?
    @ObservationIgnored private(set) var refreshing: Task<Void, Never>?

    init(read: @escaping @Sendable (String) -> FileFacts = FileFacts.read(atPath:)) {
        self.read = read
    }

    /// 读到过的信息。还没读到时返回 nil，并在这一轮画完以后交给后台去读。
    func facts(for path: String) -> FileFacts? {
        if let facts = known[path] { return facts }
        if requested.insert(path).inserted {
            queued.append(path)
            // 在画卡片的过程中不改 `known`：等这一轮画完再开始读。每一轮各读各的，
            // 一个读不完的路径（断开的网络磁盘）不会挡住之后的卡片。
            if queued.count == 1 {
                reading = Task { await self.readQueued() }
            }
        }
        return nil
    }

    private func readQueued() async {
        let paths = queued
        queued = []
        let results = await readInBackground(paths)
        var updated = known
        for (path, facts) in results {
            updated[path] = facts
        }
        known = updated
        requested.subtract(paths)
    }

    /// 在后台重读所有读过的路径，只写回变了的。上一次还没读完时不再开始一次。
    func refresh() {
        guard refreshing == nil, !known.isEmpty else { return }
        let paths = Array(known.keys)
        refreshing = Task {
            let results = await readInBackground(paths)
            let changed = results.filter { known[$0.0] != $0.1 }
            if !changed.isEmpty {
                var updated = known
                for (path, facts) in changed {
                    updated[path] = facts
                }
                known = updated
            }
            refreshing = nil
        }
    }

    private func readInBackground(_ paths: [String]) async -> [(String, FileFacts)] {
        let read = read
        return await Task.detached(priority: .utility) {
            paths.map { ($0, read($0)) }
        }.value
    }
}
