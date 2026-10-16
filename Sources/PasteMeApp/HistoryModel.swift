import Foundation
import Observation
import PasteMeCore

/// 历史面板的状态：当前搜索词、列表、选中项。
@Observable
@MainActor
final class HistoryModel {
    var query = ""
    var selectedID: Int64?
    private(set) var items: [ClipItem] = []
    /// 每次面板弹出时加一，视图据此把焦点放回搜索框。
    private(set) var showCount = 0

    /// 粘贴某个条目。
    @ObservationIgnored var onPaste: (ClipItem, PasteMode) -> Void = { _, _ in }

    @ObservationIgnored private let store: ClipStore

    init(store: ClipStore) {
        self.store = store
    }

    var selectedItem: ClipItem? {
        items.first { $0.id == selectedID } ?? items.first
    }

    func didShow() {
        query = ""
        reload()
        selectedID = items.first?.id
        showCount += 1
    }

    func reload() {
        do {
            items = try store.items(matching: ClipQuery(text: query))
        } catch {
            NSLog("PasteMe: 读取历史失败：\(error)")
            items = []
        }
        if !items.contains(where: { $0.id == selectedID }) {
            selectedID = items.first?.id
        }
    }

    func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(current + offset, 0), items.count - 1)
        selectedID = items[next].id
    }

    func paste(_ item: ClipItem? = nil, as mode: PasteMode = .original) {
        guard let item = item ?? selectedItem else { return }
        onPaste(item, mode)
    }

    /// ⌘1…⌘9：粘贴当前列表里的第 n 条。
    func paste(at index: Int, as mode: PasteMode = .original) {
        guard items.indices.contains(index) else { return }
        onPaste(items[index], mode)
    }

    func delete(_ item: ClipItem? = nil) {
        guard let item = item ?? selectedItem else { return }
        let index = items.firstIndex { $0.id == item.id }
        do {
            try store.delete(id: item.id)
        } catch {
            NSLog("PasteMe: 删除失败：\(error)")
        }
        reload()
        if let index, !items.isEmpty {
            selectedID = items[min(index, items.count - 1)].id
        }
    }
}
