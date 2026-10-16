import Foundation
import Observation
import PasteMeCore

/// 历史面板的状态：当前搜索词、列表、选中项、焦点，以及可以撤销的删除。
@Observable
@MainActor
final class HistoryModel {
    var query = ""
    var selectedID: Int64?
    private(set) var items: [ClipItem] = []
    /// 键盘操作当前作用于搜索框还是卡片列表，视图据此移动键盘焦点。
    var focus: PanelFocus = .search
    /// 每次面板弹出时加一，视图据此把焦点放回搜索框。
    private(set) var showCount = 0

    /// 粘贴某个条目。
    @ObservationIgnored var onPaste: (ClipItem, PasteMode) -> Void = { _, _ in }

    @ObservationIgnored private let store: ClipStore
    /// 本次打开面板后删除的条目，最后删除的在末尾。面板重新打开时清空。
    private var deleted: [DeletedClip] = []

    var canUndoDelete: Bool { !deleted.isEmpty }

    init(store: ClipStore) {
        self.store = store
    }

    var selectedItem: ClipItem? {
        items.first { $0.id == selectedID } ?? items.first
    }

    func didShow() {
        query = ""
        focus = .search
        deleted = []
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
            if let clip = try store.delete(id: item.id) {
                deleted.append(clip)
            }
        } catch {
            NSLog("PasteMe: 删除失败：\(error)")
        }
        reload()
        if let index, !items.isEmpty {
            selectedID = items[min(index, items.count - 1)].id
        }
    }

    /// ⌘Z：恢复最近删除的一条，并选中它。
    func undoDelete() {
        guard let clip = deleted.popLast() else { return }
        do {
            let id = try store.restore(clip)
            reload()
            selectedID = id
        } catch {
            NSLog("PasteMe: 恢复失败：\(error)")
        }
    }
}
