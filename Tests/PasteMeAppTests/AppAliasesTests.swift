import Foundation
import Testing
@testable import PasteMeApp
import PasteMeCore

/// 面板按应用的其他名字和别名搜索，以及别名窗口。
@MainActor
@Suite final class AppAliasesTests {
    let suiteName = "PasteMeTests.AppAliases.\(UUID().uuidString)"
    let settings: PasteMeCore.Settings
    let store: ClipStore
    let appNames: AppNames

    init() throws {
        settings = PasteMeCore.Settings(defaults: try #require(UserDefaults(suiteName: suiteName)))
        store = try ClipStore(path: ":memory:")
        try store.insert(ClipContent(kind: .text, text: "报销单.pdf"), source: ClipSource(bundleID: "com.apple.finder", name: "访达"))
        try store.insert(ClipContent(kind: .text, text: "晚上见"), source: ClipSource(bundleID: "com.tencent.xinWeChat", name: "微信"))
        appNames = AppNames(store: store, settings: settings) { bundleID in
            ["com.apple.finder": ["Finder", "访达"], "com.tencent.xinWeChat": ["WeChat", "微信"]][bundleID] ?? []
        }
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    @Test func panelSearchFindsEntriesByTheAppsOtherNamesAndAliases() {
        let model = HistoryModel(store: store, appNames: appNames)
        model.didShow()

        model.query = "finder"
        #expect(model.items.map(\.preview) == ["报销单.pdf"])

        settings.setAliases(["绿泡泡"], for: "com.tencent.xinWeChat")
        model.query = "app:绿泡泡"
        #expect(model.items.map(\.preview) == ["晚上见"])
    }

    @Test func aliasWindowListsOtherNamesAndSavesWhatIsTyped() {
        let window = AppAliasesModel(appNames: appNames, settings: settings)
        window.reload()

        let finder = window.rows.first { $0.bundleID == "com.apple.finder" }
        #expect(finder?.name == "访达")
        #expect(finder?.otherNames == ["Finder"])

        window.setAliasText("wx，绿泡泡, ", for: "com.tencent.xinWeChat")

        #expect(window.aliasText(for: "com.tencent.xinWeChat") == "wx，绿泡泡, ")
        #expect(settings.appAliases["com.tencent.xinWeChat"] == ["wx", "绿泡泡"])
        window.filter = "泡泡"
        #expect(window.visibleRows.map(\.bundleID) == ["com.tencent.xinWeChat"])
        window.filter = "FIND"
        #expect(window.visibleRows.map(\.bundleID) == ["com.apple.finder"])
    }
}
