import PasteMeCore
import SwiftUI
@testable import PasteMeApp

/// 记下模型要求播放的动画，不画任何东西。动画由测试调用 `finishDisappear` / `finishAppear` 结束。
@MainActor
final class FakeRemovalEffect: CardRemovalEffect {
    struct Call {
        var id: Int64
        var shortcut: Int?
        var selected = false
        var searchText: String
    }

    /// 交出了几次补位或让位的动画。
    private(set) var slideCount = 0
    var playsDisappear = true
    var playsAppear = true
    private(set) var disappeared: [Call] = []
    private(set) var appeared: [Call] = []
    private(set) var cancelCount = 0
    /// 同一张卡片的新动画取代旧的，和 `DustView` 一样。
    private var pendingDisappear: [Int64: () -> Void] = [:]
    private var pendingAppear: [Int64: () -> Void] = [:]

    func playDisappear(
        _ item: ClipItem, shortcut: Int?, selected: Bool, searchText: String,
        completion: @escaping () -> Void
    ) -> Bool {
        guard playsDisappear else { return false }
        disappeared.append(Call(id: item.id, shortcut: shortcut, selected: selected, searchText: searchText))
        pendingAppear[item.id] = nil
        pendingDisappear[item.id] = completion
        return true
    }

    func playAppear(_ item: ClipItem, shortcut: Int?, searchText: String, completion: @escaping () -> Void) -> Bool {
        guard playsAppear else { return false }
        appeared.append(Call(id: item.id, shortcut: shortcut, searchText: searchText))
        pendingDisappear[item.id] = nil
        pendingAppear[item.id] = completion
        return true
    }

    func slideAnimation() -> Animation? {
        slideCount += 1
        return nil
    }

    func cancelAll() {
        cancelCount += 1
        pendingDisappear = [:]
        pendingAppear = [:]
    }

    /// 结束一张卡片（不指定时是全部）的消失动画。
    func finishDisappear(_ id: Int64? = nil) {
        let ids = id.map { [$0] } ?? Array(pendingDisappear.keys)
        for id in ids {
            pendingDisappear.removeValue(forKey: id)?()
        }
    }

    func finishAppear() {
        let pending = pendingAppear
        pendingAppear = [:]
        pending.values.forEach { $0() }
    }
}
