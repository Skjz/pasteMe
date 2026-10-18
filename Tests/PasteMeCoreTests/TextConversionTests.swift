import Foundation
import Testing
@testable import PasteMeCore

/// 转换卡片内容（#27）。hexdump 和 C 数组的期望值是本机 `hexdump -C`、`xxd -i` 的真实输出。
@Suite struct TextConversionTests {
    private let beijing = TimeZone(identifier: "Asia/Shanghai")!

    private func convert(_ text: String, _ conversion: TextConversion) -> String? {
        TextConverter.convert(text, subtype: TextSubtype.detect(text), using: conversion, timeZone: beijing)
    }

    /// 0…39、48 个 A、ff fe 7c，和 `TextSubtypeTests` 里的 hexdump 是同一份数据。
    private let mixed = Array(0..<40).map(UInt8.init) + Array(repeating: 0x41, count: 48) + [0xff, 0xfe, 0x7c]

    @Test func hexdumpMatchesHexdumpC() {
        #expect(ByteText.hexdump(Array("Hello\n".utf8)) == """
            00000000  48 65 6c 6c 6f 0a                                 |Hello.|
            00000006
            """)
        #expect(ByteText.hexdump(mixed) == """
            00000000  00 01 02 03 04 05 06 07  08 09 0a 0b 0c 0d 0e 0f  |................|
            00000010  10 11 12 13 14 15 16 17  18 19 1a 1b 1c 1d 1e 1f  |................|
            00000020  20 21 22 23 24 25 26 27  41 41 41 41 41 41 41 41  | !"#$%&'AAAAAAAA|
            00000030  41 41 41 41 41 41 41 41  41 41 41 41 41 41 41 41  |AAAAAAAAAAAAAAAA|
            *
            00000050  41 41 41 41 41 41 41 41  ff fe 7c                 |AAAAAAAA..||
            0000005b
            """)
        #expect(ByteText.hexdump([]) == "00000000")
    }

    @Test func cArrayMatchesXxdI() {
        #expect(ByteText.cArray(Array("Hello\n".utf8)) == """
            unsigned char data[] = {
              0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x0a
            };
            unsigned int data_len = 6;
            """)
        #expect(ByteText.cArray(Array(0..<12).map(UInt8.init)) == """
            unsigned char data[] = {
              0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b
            };
            unsigned int data_len = 12;
            """)
        let lines = ByteText.cArray(mixed).split(separator: "\n")
        #expect(lines[1] == "  0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b,")
        #expect(lines[lines.count - 3] == "  0x41, 0x41, 0x41, 0x41, 0xff, 0xfe, 0x7c")
        #expect(lines.last == "unsigned int data_len = 91;")
    }

    @Test func hexToHexdumpAndBackKeepsTheBytes() throws {
        let hex = ByteText.hex(mixed)
        #expect(TextSubtype.detect(hex) == .hex)
        let dump = try #require(convert(hex, .hexdump))
        #expect(TextSubtype.detect(dump) == .hexdump)
        #expect(convert(dump, .hex) == hex)
    }

    @Test func textToBase64AndBackKeepsTheText() throws {
        for text in ["Hello, 世界", "line one\nline two\t🙂", "a"] {
            let encoded = try #require(TextConverter.convert(text, subtype: nil, using: .encodeBase64))
            #expect(TextSubtype.detect(encoded) == .base64 || encoded.count < 8, "\(encoded)")
            #expect(TextConverter.convert(encoded, subtype: .base64, using: .text) == text)
        }
        #expect(convert("SGVsbG8sIOS4lueVjA==", .text) == "Hello, 世界")
        #expect(TextConverter.convert("Hello", subtype: nil, using: .encodeBase64) == "SGVsbG8=")
    }

    @Test func xxdToCArrayAndText() {
        let xxd = "00000000: 4865 6c6c 6f0a                           Hello."
        #expect(convert(xxd, .text) == "Hello\n")
        #expect(convert(xxd, .cArray) == ByteText.cArray(Array("Hello\n".utf8)))
    }

    @Test func bytesThatAreNotUTF8CannotBecomeText() {
        let options = TextConverter.options(for: "ff fe 00 41", subtype: .hex)
        #expect(options.map(\.conversion) == [.text, .hexdump, .cArray, .encodeBase64])
        #expect(options[0].unavailableReason == "字节不是合法的 UTF-8")
        #expect(TextConverter.convert("ff fe 00 41", subtype: .hex, using: .text) == nil)
        // Base64 解码出来不是文字时，改为提供 hex 和 hexdump。
        let binary = TextConverter.options(for: "q83vEjRWeJCrze8SNFZ4kA==", subtype: .base64)
        #expect(binary.map(\.conversion) == [.hex, .hexdump, .encodeBase64])
        #expect(TextConverter.convert("q83vEjRWeJCrze8SNFZ4kA==", subtype: .base64, using: .hex) == "abcdef1234567890abcdef1234567890")
    }

    @Test func optionsDependOnTheSubtype() {
        #expect(TextConverter.options(for: "SGVsbG8=", subtype: .base64).map(\.conversion) == [.text, .encodeBase64])
        #expect(TextConverter.options(for: "1760688000", subtype: .timestamp).map(\.conversion) == [.localTime, .iso8601, .encodeBase64])
        #expect(TextConverter.options(for: "hello", subtype: nil).map(\.conversion) == [.encodeBase64])
        #expect(TextConverter.options(for: "#ff8800", subtype: .color).map(\.conversion) == [.encodeBase64])
        #expect(TextConversion.text.title(for: .base64) == "解码")
        #expect(TextConversion.text.title(for: .hex) == "ASCII 文本")
        let big = String(repeating: "a", count: TextConverter.maxLength + 1)
        #expect(TextConverter.options(for: big, subtype: nil).isEmpty)
    }

    @Test func timestampsInAFixedTimeZone() {
        #expect(convert("1760688000", .localTime) == "2025-10-17 16:00:00 GMT+8")
        #expect(convert("1760688000000", .localTime) == "2025-10-17 16:00:00 GMT+8")
        #expect(convert("1760688000123", .localTime) == "2025-10-17 16:00:00.123 GMT+8")
        #expect(convert("1760688000.5", .localTime) == "2025-10-17 16:00:00.500 GMT+8")
        #expect(convert("1760688000", .iso8601) == "2025-10-17T08:00:00Z")
        #expect(convert("1760688000123", .iso8601) == "2025-10-17T08:00:00.123Z")
        let date = Date(timeIntervalSince1970: 1_760_688_000)
        #expect(TimestampText.local(date, timeZone: TimeZone(identifier: "Asia/Kolkata")!) == "2025-10-17 13:30:00 GMT+5:30")
        #expect(TimestampText.local(date, timeZone: TimeZone(identifier: "America/Sao_Paulo")!) == "2025-10-17 05:00:00 GMT-3")
        #expect(TimestampText.local(date, timeZone: TimeZone(identifier: "UTC")!) == "2025-10-17 08:00:00 GMT")
    }
}
