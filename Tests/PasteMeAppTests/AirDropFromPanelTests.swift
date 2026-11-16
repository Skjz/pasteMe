import AppKit
import Foundation
import Testing
@testable import PasteMeApp
import PasteMeCore

/// 从卡片右键菜单发起隔空投送（#68）。
@MainActor
@Suite final class AirDropFromPanelTests {
    let store: ClipStore
    let model: HistoryModel
    var sentPlans: [AirDropPlan] = []
    var notices: [String] = []
    var airDropAvailable = true
    var existingPaths: Set<String> = ["/exists/a.pdf"]

    init() throws {
        store = try ClipStore(path: ":memory:")
        model = HistoryModel(store: store)
        model.pathKind = { [unowned self] path in existingPaths.contains(path) ? .file : nil }
        model.canAirDrop = { [unowned self] _, _ in airDropAvailable }
        model.onAirDrop = { [unowned self] plan in sentPlans.append(plan) }
        model.onNotice = { [unowned self] message, _ in notices.append(message) }
    }

    @Test func menuStateReflectsMissingFilesAndAirDropAvailability() throws {
        let missing = try store.insert(ClipContent(kind: .file, text: "/gone/one.txt"), source: nil)
        let kept = try store.insert(ClipContent(kind: .file, text: "/exists/a.pdf"), source: nil)
        let text = try store.insert(ClipContent(kind: .text, text: "hello"), source: nil)
        model.didShow()

        let missingItem = try #require(model.items.first { $0.id == missing })
        let keptItem = try #require(model.items.first { $0.id == kept })
        let textItem = try #require(model.items.first { $0.id == text })

        #expect(model.airDropMenuState(for: missingItem) == .init(title: "隔空投送…（文件已移除）", isEnabled: false))
        #expect(model.airDropMenuState(for: keptItem) == .init(title: "隔空投送…", isEnabled: true))
        #expect(model.airDropMenuState(for: textItem) == .init(title: "隔空投送…", isEnabled: true))

        airDropAvailable = false
        #expect(model.airDropMenuState(for: keptItem) == .init(title: "隔空投送…", isEnabled: false))
        #expect(model.airDropMenuState(for: textItem) == .init(title: "隔空投送…", isEnabled: false))
    }

    @Test func sendingPartiallyMissingFilesSendsRemainingAndShowsNotice() throws {
        let id = try store.insert(ClipContent(kind: .file, text: "/exists/a.pdf\n/gone/b.pdf"), source: nil)
        model.didShow()
        let item = try #require(model.items.first { $0.id == id })

        model.sendViaAirDrop(item)
        #expect(sentPlans.count == 1)
        #expect(sentPlans[0].items == [.url(URL(fileURLWithPath: "/exists/a.pdf"))])
        #expect(notices == ["有 1 个文件已移除"])
    }

    @Test func systemAirDropProbeAcceptsTextAndImagesWhenAirDropIsEnabled() {
        guard let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: [URL(string: "https://example.com")!])
        else { return }
        // 文本和图片不能因为临时文件尚未写盘而被误判为不可发送。
        #expect(AirDropController.canSend(kind: .text, urls: []))
        #expect(AirDropController.canSend(kind: .image, urls: []))
    }
}
