import Foundation
import Testing
@testable import PasteMeApp
import PasteMeCore

/// 面板上的转换（#27）：结果作为新条目记录到历史最前面并选中，原条目不变。
@MainActor
@Suite final class ConversionModelTests {
    static let notes = ClipSource(bundleID: "com.apple.Notes", name: "备忘录")

    let suiteName = "PasteMeTests.ConversionModel.\(UUID().uuidString)"
    let settings: PasteMeCore.Settings
    let store: ClipStore
    let model: HistoryModel
    let base64, plain: Int64

    init() throws {
        settings = PasteMeCore.Settings(defaults: try #require(UserDefaults(suiteName: suiteName)))
        store = try ClipStore(path: ":memory:")
        base64 = try store.insert(ClipContent(kind: .text, text: "SGVsbG8sIOS4lueVjA=="), source: Self.notes, at: Date(timeIntervalSince1970: 1))
        plain = try store.insert(ClipContent(kind: .text, text: "plain"), source: Self.notes, at: Date(timeIntervalSince1970: 2))
        model = HistoryModel(store: store, settings: settings)
        model.didShow()
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func item(_ id: Int64) throws -> ClipItem {
        try #require(try store.item(id: id))
    }

    @Test func decodingBase64AddsTheTextFirstAndSelectsIt() throws {
        let original = try item(base64)
        #expect(model.conversionOptions(for: original).map(\.conversion) == [.text, .encodeBase64])

        model.convert(original, using: .text)

        let first = try #require(model.items.first)
        #expect(first.preview == "Hello, 世界")
        #expect(model.selectedID == first.id)
        #expect(model.focus == .cards)
        // 不记来源应用；原条目还在。
        #expect(first.sourceBundleID == nil)
        #expect(model.items.map(\.id).contains(base64))
        #expect(try store.content(id: base64)?.text == "SGVsbG8sIOS4lueVjA==")
    }

    @Test func aResultThatAlreadyExistsMovesThatEntryToTheTop() throws {
        let existing = try store.insert(ClipContent(kind: .text, text: "SGVsbG8="), source: nil, at: Date(timeIntervalSince1970: 0))
        let hello = try store.insert(ClipContent(kind: .text, text: "Hello"), source: nil, at: Date(timeIntervalSince1970: 3))
        model.reload()

        model.convert(try item(hello), using: .encodeBase64)

        #expect(model.items.first?.id == existing)
        #expect(model.selectedID == existing)
    }

    @Test func convertingInsideAPinboardOrWithFiltersShowsTheResultInTheHistory() throws {
        let board = try store.createPinboard(name: "工作", color: .blue)
        try store.pin(base64, to: board.id)
        model.reloadPinboards()
        model.showTab(board.id)
        model.filters.subtypes = [.base64]

        model.convert(try item(base64), using: .text)

        #expect(model.pinboardID == nil)
        #expect(!model.filters.isActive)
        #expect(model.selectedItem?.preview == "Hello, 世界")
    }

    @Test func aDecodedAddressBecomesALink() throws {
        let encoded = try store.insert(
            ClipContent(kind: .text, text: "aHR0cHM6Ly9leGFtcGxlLmNvbS9wYXRo"), source: nil, at: Date(timeIntervalSince1970: 4)
        )
        var edited: [Int64] = []
        model.onEdited = { edited.append($0) }

        model.convert(try item(encoded), using: .text)

        let first = try #require(model.items.first)
        #expect(first.kind == .link && first.preview == "https://example.com/path")
        // 交给附加信息队列取链接预览。
        #expect(edited == [first.id])
    }

    @Test func filesHaveNoConversions() throws {
        let file = try store.insert(ClipContent(kind: .file, text: "/tmp/a.txt"), source: nil)
        #expect(model.conversionOptions(for: try item(file)).isEmpty)
    }
}
