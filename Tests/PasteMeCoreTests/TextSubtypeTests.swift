import Foundation
import Testing
@testable import PasteMeCore

/// 文本子类型的识别（#26）：整段内容符合才算，同时符合几种时按 颜色 > 时间戳 > hexdump > hex > Base64。
@Suite struct TextSubtypeTests {
    private func detect(_ text: String) -> TextSubtype? {
        TextSubtype.detect(text)
    }

    @Test func colors() {
        for text in [
            "#ff8800", "#F80", "#ff880080", "#f808", "  #FF8800\n",
            "rgb(255, 136, 0)", "rgba(255,136,0,0.5)", "rgb(255 136 0)", "rgb(255 136 0 / 50%)", "RGB(100%, 50%, 0%)",
            "hsl(32, 100%, 50%)", "hsla(32deg, 100%, 50%, .5)", "hsl(32 100% 50% / 0.5)",
        ] {
            #expect(detect(text) == .color, "\(text)")
        }
        #expect(ColorValue.parse("#ff8800") == ColorValue(red: 1, green: 136 / 255, blue: 0))
        #expect(ColorValue.parse("rgb(255 136 0 / 50%)")?.alpha == 0.5)
        let hsl = ColorValue.parse("hsl(120, 100%, 25%)")
        #expect(hsl.map { abs($0.green - 0.5) < 0.001 && $0.red == 0 && $0.blue == 0 } == true)
    }

    @Test func notColors() {
        for text in [
            "# 标题", "#123456789", "#ggg", "color: #ff8800;", "rgb(300, 0, 0)", "rgb(1, 2)",
            ".button { color: #ff8800; background: rgb(0 0 0); }", "#hashtag",
        ] {
            #expect(detect(text) != .color, "\(text)")
        }
    }

    @Test func timestamps() {
        #expect(detect("1760688000") == .timestamp)
        #expect(detect("1760688000000") == .timestamp)
        #expect(detect("1760688000.123") == .timestamp)
        #expect(UnixTimestamp.parse("1760688000000") == Date(timeIntervalSince1970: 1_760_688_000))
        #expect(UnixTimestamp.parse("1760688000.5") == Date(timeIntervalSince1970: 1_760_688_000.5))
        // 手机号、订单号、范围以外的值和 9 位数不算。
        for text in ["13812345678", "4999999999", "0000000001", "946684799", "1760688000123456", "17606880001", "1760688000.", "-1760688000"] {
            #expect(detect(text) != .timestamp, "\(text)")
        }
    }

    @Test func hexdumpFromHexdumpCAndXxd() throws {
        let canonical = """
            00000000  48 65 6c 6c 6f 0a                                 |Hello.|
            00000006
            """
        let xxd = "00000000: 4865 6c6c 6f0a                           Hello."
        #expect(detect(canonical) == .hexdump)
        #expect(detect(xxd) == .hexdump)
        #expect(ByteText.fromHexdump(canonical) == Array("Hello\n".utf8))
        #expect(ByteText.fromHexdump(xxd) == Array("Hello\n".utf8))
    }

    @Test func hexdumpWithRepeatedLinesAndBarsInTheCharacterColumn() {
        // `hexdump -C` 的真实输出：0…39、48 个 A、ff fe 7c。重复的那一行用 * 省略。
        let dump = """
            00000000  00 01 02 03 04 05 06 07  08 09 0a 0b 0c 0d 0e 0f  |................|
            00000010  10 11 12 13 14 15 16 17  18 19 1a 1b 1c 1d 1e 1f  |................|
            00000020  20 21 22 23 24 25 26 27  41 41 41 41 41 41 41 41  | !"#$%&'AAAAAAAA|
            00000030  41 41 41 41 41 41 41 41  41 41 41 41 41 41 41 41  |AAAAAAAAAAAAAAAA|
            *
            00000050  41 41 41 41 41 41 41 41  ff fe 7c                 |AAAAAAAA..||
            0000005b
            """
        let expected = Array(0..<40).map(UInt8.init) + Array(repeating: 0x41, count: 48) + [0xff, 0xfe, 0x7c]
        #expect(ByteText.fromHexdump(dump) == expected)
        let xxd = """
            00000020: 2021 2223 2425 2627 4141 4141 4141 4141   !"#$%&'AAAAAAAA
            00000030: 4141 4141 4141 4141 4141 4141 4141 4141  AAAAAAAAAAAAAAAA
            """
        #expect(ByteText.fromHexdump(xxd) == Array(32..<40).map(UInt8.init) + Array(repeating: 0x41, count: 24))
    }

    @Test func notHexdump() {
        for text in [
            "20240102  12 30",
            "00000000  48 65\n00000005  6c 6c",  // 偏移量对不上
            "0000000 6548 6c6c 000a",  // 不带 -C 的 hexdump 是按 16 位小端写的，不认
            "1234567  hello world",
        ] {
            #expect(detect(text) != .hexdump, "\(text)")
        }
    }

    @Test func hex() {
        for text in [
            "48656c6c6f2c20776f726c64", "0x48656c6c6f", "0xFF", "48 65 6c 6c 6f", "de:ad:be:ef", "\\x48\\x65\\x6c",
            "0x48, 0x65, 0x6c", "0x48 0x65", "da39a3ee5e6b4b0d3255bfef95601890afd80709",
            "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d\n1e1f2021222324252627",
        ] {
            #expect(detect(text) == .hex, "\(text)")
        }
        #expect(ByteText.fromHex("48 65 6C 6c") == [0x48, 0x65, 0x6c, 0x6c])
        #expect(ByteText.fromHex("\\x48\\x65") == [0x48, 0x65])
    }

    @Test func notHex() {
        for text in [
            "123456", "12345678901234", "cafe", "deadbeef", "face", "decade", "12:30:45", "a1",
            "0x1", "48656c6c6", "550e8400-e29b-41d4-a716-446655440000", "ab cd", "10, 20, 30, 40",
        ] {
            #expect(detect(text) != .hex, "\(text)")
        }
    }

    @Test func base64() {
        for text in [
            "SGVsbG8sIOS4lueVjA==", "SGVsbG8=", "aGVsbG8gd29ybGQ", "PGh0bWw+PC9odG1sPg==",
            "q83vEjRWeJCrze8SNFZ4kA==", "q83vEjRWeJCrze8SNFZ4kA", "F5Jn-9T2qIh0bwr-mfopq4Di",
            "TG9yZW0gaXBzdW0gZG9sb3Igc2l0IGFtZXQsIGNvbnNlY3RldHVyIGFkaXBp\nc2NpbmcgZWxpdC4=",
        ] {
            #expect(detect(text) == .base64, "\(text)")
        }
        #expect(ByteText.fromBase64("SGVsbG8sIOS4lueVjA==").flatMap { String(bytes: $0, encoding: .utf8) } == "Hello, 世界")
    }

    @Test func plainTextIsNoSubtype() {
        for text in [
            "function", "hello", "Hello world", "你好，世界", "这是一段中文。", "13812345678", "2025102112345678",
            "550e8400-e29b-41d4-a716-446655440000", "550E8400-E29B-41D4-A716-446655440000",
            "# 标题", "## Heading", "myVariableName2024", "SomeClassName123Foo", "getUserById",
            "/usr/local/bin/python3", "/Users/lixiang/Documents/Project2", "https://example.com",
            "a.b.c", "Version 2.0.1", "3.14159", "", "   ",
        ] {
            #expect(detect(text) == nil, "\(text)")
        }
    }

    @Test func gitCommitHashIsHexButNotBase64() {
        let hash = "da39a3ee5e6b4b0d3255bfef95601890afd80709"
        #expect(detect(hash) == .hex)
        #expect(!TextSubtype.looksLikeBase64(hash))
    }

    @Test func textInsideAParagraphIsNotDetected() {
        #expect(detect("颜色是 #ff8800，时间是 1760688000。") == nil)
        #expect(detect("SGVsbG8sIOS4lueVjA== is base64") == nil)
    }

    @Test func overOneMegabyteIsNotDetected() {
        let big = String(repeating: "ab12", count: TextSubtype.maxLength / 4 + 1)
        #expect(TextSubtype.detect(big) == nil)
    }

    @Test func rawValuesRoundTrip() {
        let all: [TextSubtype] = [.color, .timestamp, .hexdump, .hex, .base64] + CodeLanguage.allCases.map(TextSubtype.code)
        for subtype in all {
            #expect(TextSubtype(rawValue: subtype.rawValue) == subtype)
        }
        #expect(TextSubtype(rawValue: "code") == nil)
        #expect(TextSubtype(rawValue: "code:cobol") == nil)
        #expect(TextSubtype(rawValue: "") == nil)
    }

    @Test func searchNames() {
        #expect(TextSubtype.Category.matching("hex") == [.hexdump, .hex])
        #expect(TextSubtype.Category.matching("时间") == [.timestamp])
        #expect(TextSubtype.Category.matching("Base") == [.base64])
        #expect(TextSubtype.Category.matching("").count == TextSubtype.Category.allCases.count)
    }

    @Test func storeDetectsOnInsertAndAfterEditing() throws {
        let store = try ClipStore(path: ":memory:")
        let id = try store.insert(ClipContent(kind: .text, text: "1760688000"), source: nil)
        #expect(try store.item(id: id)?.textSubtype == .timestamp)
        try store.updateText("#ff8800", rtf: nil, id: id)
        #expect(try store.item(id: id)?.textSubtype == .color)
        try store.updateText("just words", rtf: nil, id: id)
        #expect(try store.item(id: id)?.textSubtype == nil)
        let link = try store.insert(ClipContent(kind: .link, text: "https://example.com"), source: nil)
        #expect(try store.item(id: link)?.textSubtype == nil)
        // 识别过的条目不再补算。
        #expect(try store.backfillTextSubtypes() == 0)
    }
}
