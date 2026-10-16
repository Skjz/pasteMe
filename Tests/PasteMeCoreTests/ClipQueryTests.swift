import Foundation
import Testing
@testable import PasteMeCore

@Suite struct ClipQueryTests {
    let store: ClipStore

    init() throws {
        store = try ClipStore(path: ":memory:")
    }

    @Test func textMatchesTextAndSourceNameCaseInsensitively() throws {
        try store.insert(ClipContent(kind: .text, text: "Hello World"), source: nil)
        try store.insert(ClipContent(kind: .text, text: "other"), source: ClipSource(bundleID: nil, name: "Safari"))
        try store.insert(ClipContent(kind: .text, text: "unrelated"), source: nil)

        #expect(try store.items(matching: ClipQuery(text: "hello")).map(\.preview) == ["Hello World"])
        #expect(try store.items(matching: ClipQuery(text: "safari")).map(\.preview) == ["other"])
        #expect(try store.items(matching: ClipQuery(text: "  ")).count == 3)
    }

    @Test func textTreatsLikeWildcardsLiterally() throws {
        try store.insert(ClipContent(kind: .text, text: "100% done"), source: nil)
        try store.insert(ClipContent(kind: .text, text: "100 done"), source: nil)
        try store.insert(ClipContent(kind: .text, text: "a_b"), source: nil)
        try store.insert(ClipContent(kind: .text, text: "axb"), source: nil)

        #expect(try store.items(matching: ClipQuery(text: "100%")).map(\.preview) == ["100% done"])
        #expect(try store.items(matching: ClipQuery(text: "a_b")).map(\.preview) == ["a_b"])
    }

    @Test func limitKeepsNewestItems() throws {
        for i in 1...5 {
            try store.insert(ClipContent(kind: .text, text: "item \(i)"), source: nil, at: Date(timeIntervalSince1970: Double(i)))
        }

        #expect(try store.items(matching: ClipQuery(limit: 2)).map(\.preview) == ["item 5", "item 4"])
        #expect(try store.items(matching: ClipQuery(text: "item", limit: 3)).count == 3)
    }
}
