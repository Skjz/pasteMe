import Foundation
import Testing
@testable import PasteMeCore

/// 应用的其他名字和别名：从应用包里读名字、拆分别名、按名字找应用、搜索结果。
@MainActor
@Suite final class AppNamesTests {
    static let finder = ClipSource(bundleID: "com.apple.finder", name: "访达")
    static let wechat = ClipSource(bundleID: "com.tencent.xinWeChat", name: "微信")
    nonisolated static let systemNames = [
        "com.apple.finder": ["Finder", "访达"],
        "com.tencent.xinWeChat": ["WeChat", "微信"],
    ]

    let suiteName = "PasteMeTests.AppNames.\(UUID().uuidString)"
    let settings: Settings
    let store: ClipStore
    let lookups = Counter()

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    init() throws {
        settings = Settings(defaults: try #require(UserDefaults(suiteName: suiteName)))
        store = try ClipStore(path: ":memory:")
        try store.insert(ClipContent(kind: .text, text: "报销单.pdf"), source: Self.finder, at: Date(timeIntervalSince1970: 1))
        try store.insert(ClipContent(kind: .text, text: "晚上见"), source: Self.wechat, at: Date(timeIntervalSince1970: 2))
        try store.insert(ClipContent(kind: .text, text: "no app"), source: nil, at: Date(timeIntervalSince1970: 3))
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func makeNames() -> AppNames {
        let lookups = lookups
        return AppNames(store: store, settings: settings) { bundleID in
            lookups.increment()
            return Self.systemNames[bundleID] ?? []
        }
    }

    func search(_ input: String, with names: AppNames) throws -> [String?] {
        let query = ClipQuery.parse(input).resolvingAppNames { names.bundleIDs(matching: $0) }
        return try store.items(matching: query).map(\.preview)
    }

    @Test func finderDeclaresItsEnglishAndChineseNames() {
        let names = AppBundleNames.names(ofBundleID: "com.apple.finder", languages: ["zh-Hans"])
        #expect(names.contains("Finder"))
        #expect(names.contains("访达"))
        #expect(!AppBundleNames.names(ofBundleID: "com.apple.finder", languages: ["en"]).contains("访达"))
    }

    @Test func unknownAppHasNoNames() {
        #expect(AppBundleNames.names(ofBundleID: "io.github.skjz.no-such-app").isEmpty)
    }

    @Test func aliasTextSplitsOnCommasAndSemicolonsButNotSpaces() {
        #expect(AppAlias.parse("wx, 绿泡泡，vx、 WX ;System Preferences；\n") == ["wx", "绿泡泡", "vx", "System Preferences"])
        #expect(AppAlias.parse("  ").isEmpty)
        #expect(AppAlias.format(["wx", "vx"]) == "wx, vx")
    }

    @Test func appsAreFoundByAnyOfTheirNames() {
        let names = makeNames()
        #expect(names.bundleIDs(matching: "finder") == ["com.apple.finder"])
        #expect(names.bundleIDs(matching: "FIN") == ["com.apple.finder"])
        #expect(names.bundleIDs(matching: "微") == ["com.tencent.xinWeChat"])
        #expect(names.bundleIDs(matching: "ｗｅｃｈａｔ") == ["com.tencent.xinWeChat"])
        #expect(names.bundleIDs(matching: " ").isEmpty)
        #expect(names.bundleIDs(matching: "safari").isEmpty)
    }

    @Test func aliasesTakeEffectWithoutReloading() {
        let names = makeNames()
        #expect(names.bundleIDs(matching: "wx").isEmpty)

        settings.setAliases(["wx"], for: "com.tencent.xinWeChat")

        #expect(names.bundleIDs(matching: "wx") == ["com.tencent.xinWeChat"])
    }

    @Test func appsWhoseNameStartsWithTheTextComeFirst() {
        let names = makeNames()
        settings.setAliases(["chooser"], for: "com.apple.finder")

        // 两个应用都只有一条条目，按条目数排时微信（较新）在前；访达的别名以 ch 开头，排到前面。
        #expect(names.apps(matching: "").map(\.bundleID) == ["com.tencent.xinWeChat", "com.apple.finder"])
        #expect(names.apps(matching: "ch").map(\.bundleID) == ["com.apple.finder", "com.tencent.xinWeChat"])
        #expect(names.apps(matching: "safari").isEmpty)
    }

    @Test func searchingAnEnglishNameFindsEntriesRecordedUnderTheChineseName() throws {
        let names = makeNames()
        settings.setAliases(["绿泡泡"], for: "com.tencent.xinWeChat")

        #expect(try search("finder", with: names) == ["报销单.pdf"])
        #expect(try search("app:wechat", with: names) == ["晚上见"])
        #expect(try search("app:绿泡泡", with: names) == ["晚上见"])
        #expect(try search("app:访达", with: names) == ["报销单.pdf"])
        // 按应用名找到的条目和按文字找到的条目合在一起。
        #expect(try search("no", with: names).contains("no app"))
    }

    @Test func newSourceAppsShowUpAfterHistoryChanged() throws {
        let names = makeNames()
        #expect(names.bundleIDs(matching: "notes").isEmpty)
        try store.insert(ClipContent(kind: .text, text: "x"), source: ClipSource(bundleID: "com.apple.Notes", name: "Notes"))
        #expect(names.bundleIDs(matching: "notes").isEmpty)

        names.historyChanged()

        #expect(names.bundleIDs(matching: "notes") == ["com.apple.Notes"])
    }

    @Test func prefetchReadsEveryAppOnceInTheBackground() async {
        let names = makeNames()
        await names.prefetch()
        #expect(lookups.count == 2)

        _ = names.bundleIDs(matching: "finder")
        await names.prefetch()

        #expect(lookups.count == 2)
    }
}
