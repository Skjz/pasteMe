import Foundation
import Testing
@testable import PasteMeApp
import PasteMeCore

@MainActor
@Suite struct TextSnippetTests {
    func image(_ text: String?) -> ClipItem {
        ClipItem(
            id: 1, kind: .image, preview: nil, textLength: 0, thumbnail: nil,
            sourceBundleID: nil, sourceName: nil, createdAt: Date(), recognizedText: text
        )
    }

    @Test func snippetShowsMatchWithSurroundingTextOnOneLine() {
        let item = image("开票日期 2026年10月16日\n增值税专用发票\n购买方名称 某某公司")

        #expect(item.recognizedTextSnippet(matching: "发票") == TextSnippet(
            before: "… 增值税专用",
            match: "发票",
            after: " 购买方名称 某某公司"
        ))
    }

    @Test func snippetIgnoresCaseAndMarksTruncatedEnds() {
        let item = image("Total amount due: 42.00 USD, please pay by Friday")

        let snippet = item.recognizedTextSnippet(matching: "AMOUNT", context: 3)
        #expect(snippet == TextSnippet(before: "…al ", match: "amount", after: " due: 42.…"))
    }

    @Test func noSnippetWithoutMatchOrRecognizedText() {
        #expect(image("hello").recognizedTextSnippet(matching: "bye") == nil)
        #expect(image("hello").recognizedTextSnippet(matching: "  ") == nil)
        #expect(image(nil).recognizedTextSnippet(matching: "hello") == nil)
    }
}
