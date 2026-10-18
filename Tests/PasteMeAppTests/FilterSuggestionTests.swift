import Foundation
import Testing
@testable import PasteMeApp
import PasteMeCore

/// 搜索框里输入 `@` 后的候选列表：列出哪些项、写到一半时怎么搜索、选中后变成筛选条件、esc 关掉后按文字搜索。
@MainActor
@Suite final class FilterSuggestionTests {
    static let finder = ClipSource(bundleID: "com.apple.finder", name: "访达")
    static let wechat = ClipSource(bundleID: "com.tencent.xinWeChat", name: "微信")

    let suiteName = "PasteMeTests.FilterSuggestion.\(UUID().uuidString)"
    let settings: PasteMeCore.Settings
    let store: ClipStore
    let model: HistoryModel

    init() throws {
        settings = PasteMeCore.Settings(defaults: try #require(UserDefaults(suiteName: suiteName)))
        store = try ClipStore(path: ":memory:")
        try store.insert(ClipContent(kind: .text, text: "报销单.pdf"), source: Self.finder, at: Date(timeIntervalSince1970: 1))
        try store.insert(ClipContent(kind: .text, text: "晚上见"), source: Self.wechat, at: Date(timeIntervalSince1970: 2))
        try store.insert(ClipContent(kind: .link, text: "https://example.com"), source: Self.wechat, at: Date(timeIntervalSince1970: 3))
        try store.insert(ClipContent(kind: .text, text: "me@gmail.com"), source: nil, at: Date(timeIntervalSince1970: 4))
        let appNames = AppNames(store: store, settings: settings) { bundleID in
            ["com.apple.finder": ["Finder", "访达"], "com.tencent.xinWeChat": ["WeChat", "微信"]][bundleID] ?? []
        }
        model = HistoryModel(store: store, appNames: appNames)
        model.didShow()
        model.focus = .search
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    var previews: [String?] { model.items.map(\.preview) }

    @Test func typingAtListsEveryKindAndTextSubtypeThenEveryApp() {
        model.query = "@"

        #expect(model.suggestions.map(\.id) == [
            "kind:text", "kind:link", "kind:image", "kind:file",
            "subtype:color", "subtype:timestamp", "subtype:hexdump", "subtype:hex", "subtype:base64", "subtype:code",
            "app:com.tencent.xinWeChat", "app:com.apple.finder",
        ])
        #expect(model.showsSuggestions)
    }

    @Test func choosingATextSubtypeShowsOnlyThoseEntries() throws {
        try store.insert(ClipContent(kind: .text, text: "1760688000"), source: nil, at: Date(timeIntervalSince1970: 5))
        model.reload()
        model.query = "@时间"
        #expect(model.suggestions.map(\.id) == ["subtype:timestamp"])

        model.acceptSuggestion()
        #expect(model.query == "")
        #expect(model.filters.subtypes == [.timestamp])
        #expect(previews == ["1760688000"])
        #expect(model.activeConditions == ["是时间戳"])
    }

    @Test func appsAreFoundByTheirOtherNamesAndAliases() {
        settings.setAliases(["wx"], for: "com.tencent.xinWeChat")

        model.query = "@wx"
        #expect(model.suggestions.map(\.id) == ["app:com.tencent.xinWeChat"])
        model.query = "@finder"
        #expect(model.suggestions.map(\.id) == ["app:com.apple.finder"])
    }

    @Test func theUnfinishedWordDoesNotNarrowTheResults() {
        model.query = "@we"
        #expect(previews.count == 4)

        model.query = "晚 @we"
        #expect(previews == ["晚上见"])
    }

    @Test func acceptingTheHighlightedSuggestionTurnsItIntoAFilter() {
        model.query = "@fin"
        model.acceptSuggestion()

        #expect(model.query.isEmpty)
        #expect(model.filters.sourceApp?.bundleID == "com.apple.finder")
        #expect(model.suggestions.isEmpty)
        #expect(previews == ["报销单.pdf"])
    }

    @Test func textBeforeTheWordStaysInTheSearchField() {
        model.query = "晚 @微"
        model.acceptSuggestion()

        #expect(model.query == "晚 ")
        #expect(previews == ["晚上见"])
    }

    @Test func movingTheHighlightStopsAtTheEnds() {
        model.query = "@文"
        #expect(model.suggestions == [.kind(.text), .kind(.file)])

        model.moveSuggestion(by: -1)
        #expect(model.suggestionIndex == 0)
        model.moveSuggestion(by: 5)
        #expect(model.suggestionIndex == 1)

        model.acceptSuggestion()
        #expect(model.filters.kinds == [.file])
    }

    @Test func clickingASuggestionAcceptsThatOne() {
        model.query = "@"
        model.acceptSuggestion(.kind(.link))

        #expect(model.filters.kinds == [.link])
        #expect(previews == ["https://example.com"])
    }

    @Test func escapeSearchesTheWordAsTextUntilItIsFinished() {
        model.query = "@"
        model.dismissSuggestions()

        #expect(model.suggestions.isEmpty)
        #expect(previews == ["me@gmail.com"])
        // 接着写也不再弹出列表。
        model.query = "@w"
        #expect(model.suggestions.isEmpty)

        // 写完这个词以后，下一个 @ 照常弹出列表。
        model.query = "@w @"
        #expect(!model.suggestions.isEmpty)
    }

    @Test func wordsWithNoSuggestionsAreSearchedAsText() {
        model.query = "@gmail"
        #expect(model.suggestions.isEmpty)
        #expect(previews == ["me@gmail.com"])

        model.query = "me@g"
        #expect(model.suggestions.isEmpty)
        #expect(previews == ["me@gmail.com"])
    }

    @Test func listIsHiddenWhileTheCardsHaveFocus() {
        model.query = "@"
        model.focus = .cards
        #expect(!model.showsSuggestions)
    }

    @Test func reopeningThePanelClosesTheList() {
        model.query = "@"
        model.didShow()
        #expect(model.suggestions.isEmpty)
    }

    @Test func withoutAppNamesAppsAreMatchedByTheRecordedName() {
        let plain = HistoryModel(store: store)
        plain.didShow()
        plain.query = "@微"
        #expect(plain.suggestions.map(\.id) == ["app:com.tencent.xinWeChat"])
    }
}
