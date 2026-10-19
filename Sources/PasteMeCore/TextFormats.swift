import Foundation

/// 文本写出的颜色值：`#RGB`、`#RGBA`、`#RRGGBB`、`#RRGGBBAA`，以及 CSS 的 `rgb()`、`rgba()`、`hsl()`、`hsla()`
/// （逗号分隔和空格分隔两种写法）。各分量在 0…1 之间，sRGB。
public struct ColorValue: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static func parse(_ text: String) -> ColorValue? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.utf8.count <= 64 else { return nil }
        if s.hasPrefix("#") { return hexColor(s.dropFirst()) }
        let lower = s.lowercased()
        for name in ["rgba", "rgb", "hsla", "hsl"] where lower.hasPrefix(name + "(") {
            guard lower.hasSuffix(")") else { return nil }
            let inner = lower.dropFirst(name.count + 1).dropLast()
            return function(isHSL: name.hasPrefix("hsl"), arguments: inner)
        }
        return nil
    }

    private static func hexColor(_ digits: Substring) -> ColorValue? {
        guard [3, 4, 6, 8].contains(digits.count), digits.utf8.allSatisfy(ByteText.isHexDigit) else { return nil }
        let short = digits.count <= 4
        let step = short ? 1 : 2
        var values: [Double] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: step)
            var part = String(digits[index..<next])
            if short { part += part }
            values.append(Double(Int(part, radix: 16)!) / 255)
            index = next
        }
        return ColorValue(red: values[0], green: values[1], blue: values[2], alpha: values.count == 4 ? values[3] : 1)
    }

    /// `255, 136, 0` / `255 136 0 / 50%` 这样的参数。
    private static func function(isHSL: Bool, arguments: Substring) -> ColorValue? {
        var parts: [Substring]
        var alphaPart: Substring?
        if arguments.contains(",") {
            parts = arguments.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces)[...] }
            guard parts.count == 3 || parts.count == 4 else { return nil }
            if parts.count == 4 { alphaPart = parts.removeLast() }
        } else {
            let halves = arguments.split(separator: "/", omittingEmptySubsequences: false)
            guard halves.count <= 2 else { return nil }
            parts = halves[0].split(whereSeparator: \.isWhitespace)
            guard parts.count == 3 else { return nil }
            if halves.count == 2 {
                alphaPart = halves[1].trimmingCharacters(in: .whitespaces)[...]
            }
        }
        var alpha = 1.0
        if let alphaPart {
            guard let value = fraction(alphaPart, scale: 1) else { return nil }
            alpha = value
        }
        if isHSL {
            var hueText = parts[0]
            if hueText.hasSuffix("deg") { hueText = hueText.dropLast(3) }
            guard let hue = Double(hueText), let saturation = fraction(parts[1], scale: 100),
                  let lightness = fraction(parts[2], scale: 100)
            else { return nil }
            return hsl(hue: hue, saturation: saturation, lightness: lightness, alpha: alpha)
        }
        let channels = parts.compactMap { fraction($0, scale: 255) }
        guard channels.count == 3 else { return nil }
        return ColorValue(red: channels[0], green: channels[1], blue: channels[2], alpha: alpha)
    }

    /// `50%`，或者不带 % 的数（按 `scale` 换算），结果要在 0…1 之间。
    private static func fraction(_ text: Substring, scale: Double) -> Double? {
        let value: Double?
        if text.hasSuffix("%") {
            value = Double(text.dropLast()).map { $0 / 100 }
        } else {
            value = Double(text).map { $0 / scale }
        }
        guard let value, (0...1).contains(value) else { return nil }
        return value
    }

    private static func hsl(hue: Double, saturation s: Double, lightness l: Double, alpha: Double) -> ColorValue {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        func channel(_ offset: Double) -> Double {
            let k = (offset + h * 12).truncatingRemainder(dividingBy: 12)
            return l - s * min(l, 1 - l) * max(-1, min(k - 3, 9 - k, 1))
        }
        return ColorValue(red: channel(0), green: channel(8), blue: channel(4), alpha: alpha)
    }
}

/// Unix 时间戳：10 位整数是秒（可以带小数），13 位整数是毫秒。
/// 只认 2000-01-01 到 2100-01-01 之间的值，减少把普通数字当成时间戳。
public enum UnixTimestamp {
    static let validSeconds = 946_684_800.0 ..< 4_102_444_800.0

    public static func parse(_ text: String) -> Date? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.utf8.count <= 24 else { return nil }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy(ByteText.isDigit) }) else {
            return nil
        }
        let seconds: Double
        switch (parts[0].count, parts.count) {
        case (10, 1): seconds = Double(parts[0])!
        case (10, 2) where parts[1].count <= 9: seconds = Double(s)!
        case (13, 1): seconds = Double(parts[0])! / 1000
        default: return nil
        }
        guard validSeconds.contains(seconds) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// 字节的几种文本写法：hex、hexdump（`hexdump -C` 和 `xxd`）、Base64、C 数组。
/// 识别（`TextSubtype.detect`）和转换（`TextConversion`）共用这里的解析。
public enum ByteText {
    static func isDigit(_ c: UInt8) -> Bool { (48...57).contains(c) }

    static func isHexDigit(_ c: UInt8) -> Bool {
        isDigit(c) || (97...102).contains(c) || (65...70).contains(c)
    }

    private static func hexValue(_ c: UInt8) -> UInt8 {
        switch c {
        case 48...57: c - 48
        case 97...102: c - 87
        default: c - 55
        }
    }

    /// 偶数位的十六进制数字转成字节。
    private static func bytes(fromHexDigits digits: some Collection<UInt8>) -> [UInt8]? {
        guard digits.count % 2 == 0, digits.allSatisfy(isHexDigit) else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(digits.count / 2)
        var high: UInt8?
        for digit in digits {
            if let h = high {
                result.append(h << 4 | hexValue(digit))
                high = nil
            } else {
                high = hexValue(digit)
            }
        }
        return result
    }

    // MARK: - hex

    /// 解析 hex，不是时为 nil。认这几种写法：
    ///
    /// - 每个字节带前缀：`0x48 0x65`、`0x48, 0x65`、`\x48\x65`；或者整串一个前缀：`0x48656c6c6f`。
    /// - 字节之间用空格或冒号隔开：`48 65 6c 6c`、`de:ad:be:ef`，至少 4 个字节（`12:30:45` 是时间）。
    /// - 连续的数字，可以按行折开（`xxd -p`）：至少 8 位，数字和 a–f 字母都有。
    ///   纯十进制数字（订单号、手机号）和 `cafe`、`deadbeef` 这样只有字母的词不算。
    public static func fromHex(_ text: String) -> [UInt8]? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = Set(" \t\r\n:,xX\\".utf8)
        guard !s.isEmpty, s.utf8.allSatisfy({ isHexDigit($0) || allowed.contains($0) }) else { return nil }

        if s.hasPrefix("\\x") {
            let parts = s.components(separatedBy: "\\x").dropFirst()
            guard parts.allSatisfy({ $0.utf8.count == 2 }) else { return nil }
            return bytes(fromHexDigits: parts.joined().utf8)
        }
        let tokens = s.split(whereSeparator: { $0.isWhitespace || $0 == ":" || $0 == "," })
        if tokens.allSatisfy({ $0.hasPrefix("0x") || $0.hasPrefix("0X") }) {
            let digits = tokens.map { $0.dropFirst(2) }
            if tokens.count > 1 { guard digits.allSatisfy({ $0.utf8.count == 2 }) else { return nil } }
            guard let bytes = bytes(fromHexDigits: digits.joined().utf8), !bytes.isEmpty else { return nil }
            return bytes
        }
        guard !s.contains(","), !s.contains("x"), !s.contains("X"), !s.contains("\\") else { return nil }
        if s.contains(" ") || s.contains(":") || s.contains("\t") {
            guard tokens.count >= 4, tokens.allSatisfy({ $0.utf8.count == 2 }) else { return nil }
            return bytes(fromHexDigits: tokens.joined().utf8)
        }
        let digits = tokens.joined().utf8
        guard digits.count >= 8, tokens.allSatisfy({ $0.utf8.count % 2 == 0 }),
              digits.contains(where: isDigit), !digits.allSatisfy(isDigit)
        else { return nil }
        return bytes(fromHexDigits: digits)
    }

    /// 小写、连续、不带前缀，例如 `48656c6c6f`。
    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - hexdump

    private enum DumpStyle {
        /// `hexdump -C`：偏移量后两个空格，每个字节两位，右边 `|字符栏|`，最后一行只有总长度。
        /// 抓包工具等拷出来的同类格式也算：每行字节数不限，字符栏可以不带竖线。
        case canonical
        /// `xxd`：偏移量后是冒号和空格，两个字节一组，右边两个空格后是字符栏。
        case xxd
    }

    /// 解析 `hexdump -C` 或 `xxd` 的输出，不是时为 nil。
    ///
    /// 每行是偏移量、若干字节的十六进制和可选的字符栏；偏移量要和前面的字节数对得上（可以从中间某行开始复制），
    /// `hexdump -C` 用 `*` 省略的重复行按上一行补回。只有一行时要带字符栏，免得把「20240102  12 30」这样的文字当成 hexdump。
    public static func fromHexdump(_ text: String) -> [UInt8]? {
        guard let first = text.utf8.first, isHexDigit(first) else { return nil }
        var bytes: [UInt8] = []
        var style: DumpStyle?
        var start: Int?
        var previousLine: [UInt8] = []
        var repeating = false
        var ended = false
        var lineCount = 0
        var sawCharacterColumn = false

        /// 下一行的偏移量要接着前面的字节；前面是 `*` 时，先用上一行补满中间省略的部分。
        func advance(to offset: Int) -> Bool {
            guard let start else { return true }
            let expected = start + bytes.count
            if repeating {
                let gap = offset - expected
                guard gap >= 0, !previousLine.isEmpty, gap % previousLine.count == 0 else { return false }
                for _ in 0..<(gap / previousLine.count) { bytes += previousLine }
                repeating = false
                return true
            }
            return offset == expected
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard !ended else { return nil }
            lineCount += 1
            if line == "*" {
                guard style == .canonical, !repeating, !previousLine.isEmpty else { return nil }
                repeating = true
                continue
            }
            let offsetDigits = line.utf8.prefix(while: isHexDigit)
            guard (7...16).contains(offsetDigits.count),
                  let offset = Int(String(decoding: offsetDigits, as: UTF8.self), radix: 16)
            else { return nil }
            let rest = line.dropFirst(offsetDigits.count)

            if rest.isEmpty {
                // `hexdump -C` 的最后一行：总长度。
                guard style == .canonical, advance(to: offset) else { return nil }
                ended = true
                continue
            }

            let lineStyle: DumpStyle
            var lineBytes: [UInt8] = []
            if rest.hasPrefix(": ") {
                lineStyle = .xxd
                var hexArea = rest.dropFirst(2)
                if let gap = hexArea.range(of: "  ") {
                    hexArea = hexArea[..<gap.lowerBound]
                    sawCharacterColumn = true
                }
                for group in hexArea.split(whereSeparator: \.isWhitespace) {
                    guard let parsed = Self.bytes(fromHexDigits: group.utf8), !parsed.isEmpty else { return nil }
                    lineBytes += parsed
                }
            } else if rest.hasPrefix("  "), let parsed = canonicalLine(rest.dropFirst(2).utf8) {
                lineStyle = .canonical
                lineBytes = parsed.bytes
                if parsed.hasCharacterColumn { sawCharacterColumn = true }
            } else {
                return nil
            }
            guard style == nil || style == lineStyle else { return nil }
            style = lineStyle
            guard !lineBytes.isEmpty, advance(to: offset) else { return nil }
            if start == nil { start = offset }
            bytes += lineBytes
            previousLine = lineBytes
        }
        guard !bytes.isEmpty, !repeating, sawCharacterColumn || lineCount >= 2 else { return nil }
        return bytes
    }

    /// `hexdump -C` 这类的一行在偏移量之后的部分：一个个两位的字节，右边可以有字符栏。
    /// 字符栏或者用竖线围起来（`|Hello.|`），或者不带竖线、和字节隔开至少两个空格（`Hello.`）。
    /// 不带竖线时字符栏要和字节一个个对得上；字符栏开头像字节时（比如 `ab cd`），少算几个字节再对。
    private static func canonicalLine(_ body: Substring.UTF8View) -> (bytes: [UInt8], hasCharacterColumn: Bool)? {
        let line = Array(body)
        var bytes: [UInt8] = []
        var ends: [Int] = []
        var index = 0
        while true {
            var start = index
            while start < line.count, isSpace(line[start]) { start += 1 }
            let end = start + 2
            guard end <= line.count, isHexDigit(line[start]), isHexDigit(line[start + 1]),
                  end == line.count || isSpace(line[end])
            else { break }
            bytes.append(hexValue(line[start]) << 4 | hexValue(line[start + 1]))
            ends.append(end)
            index = end
        }
        guard !bytes.isEmpty else { return nil }
        let column = line[index...].drop(while: isSpace)
        if column.isEmpty { return (bytes, false) }
        if column.count >= 2, column.first == UInt8(ascii: "|"), column.last == UInt8(ascii: "|") {
            return (bytes, true)
        }
        for count in stride(from: bytes.count, to: 0, by: -1)
        where characterColumn(line[ends[count - 1]...], shows: bytes[..<count]) {
            return (Array(bytes[..<count]), true)
        }
        return nil
    }

    private static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 }

    /// `text` 是字节后面的部分：至少两个空格，然后是字符栏，可打印的 ASCII 原样显示，其他字节显示成 `.`。
    /// 行尾的空格已经去掉了，所以末尾是 0x20 的字节不比。
    private static func characterColumn(_ text: ArraySlice<UInt8>, shows bytes: ArraySlice<UInt8>) -> Bool {
        var shown = bytes
        while shown.last == 0x20 { shown.removeLast() }
        let gap = text.count - shown.count
        guard gap >= 2, text.prefix(gap).allSatisfy(isSpace) else { return false }
        return zip(text.suffix(shown.count), shown).allSatisfy { character, byte in
            character == ((0x20...0x7e).contains(byte) ? byte : UInt8(ascii: "."))
        }
    }

    /// `hexdump -C` 的格式：8 位偏移量，每行 16 字节，右边是字符栏，和上一行相同的行用 `*` 省略，最后一行是总长度。
    public static func hexdump(_ bytes: [UInt8]) -> String {
        var lines: [String] = []
        var previous: ArraySlice<UInt8>?
        var skipping = false
        var offset = 0
        while offset < bytes.count {
            let line = bytes[offset..<min(offset + 16, bytes.count)]
            if line.count == 16, let previous, previous.elementsEqual(line) {
                if !skipping { lines.append("*") }
                skipping = true
            } else {
                skipping = false
                var hex = ""
                for i in 0..<16 {
                    hex += i < line.count ? String(format: "%02x ", line[line.startIndex + i]) : "   "
                    if i == 7 { hex += " " }
                }
                let characters = String(line.map { (0x20...0x7e).contains($0) ? Character(Unicode.Scalar($0)) : "." })
                lines.append(String(format: "%08x  ", offset) + hex + " |" + characters + "|")
            }
            previous = line
            offset += line.count
        }
        lines.append(String(format: "%08x", bytes.count))
        return lines.joined(separator: "\n")
    }

    // MARK: - C 数组

    /// 和 `xxd -i` 一样的 C 数组：每行 12 个字节、缩进两个空格，最后给出长度。
    public static func cArray(_ bytes: [UInt8], name: String = "data") -> String {
        var lines = ["unsigned char \(name)[] = {"]
        var index = 0
        while index < bytes.count {
            let end = min(index + 12, bytes.count)
            let row = bytes[index..<end].map { String(format: "0x%02x", $0) }.joined(separator: ", ")
            lines.append("  " + row + (end < bytes.count ? "," : ""))
            index = end
        }
        lines.append("};")
        lines.append("unsigned int \(name)_len = \(bytes.count);")
        return lines.joined(separator: "\n")
    }

    // MARK: - Base64

    /// 按 Base64 解码，不是合法的 Base64 时为 nil。标准字母表和 URL 安全字母表都认，带不带 `=` 补齐都可以。
    /// 只在每行一样长的时候（MIME 那样按固定宽度折行）允许换行。是不是像 Base64 的判断在 `TextSubtype`。
    public static func fromBase64(_ text: String) -> [UInt8]? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains(where: \.isNewline) {
            let lines = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let width = lines.first?.utf8.count, width >= 16,
                  lines.dropLast().allSatisfy({ $0.utf8.count == width }), lines.last!.utf8.count <= width
            else { return nil }
            s = lines.joined()
        }
        let utf8 = s.utf8
        let padding = utf8.reversed().prefix(while: { $0 == UInt8(ascii: "=") }).count
        let body = utf8.dropLast(padding)
        guard !body.isEmpty, padding <= 2, body.count % 4 != 1, padding == 0 || utf8.count % 4 == 0 else { return nil }
        func isLetterOrDigit(_ c: UInt8) -> Bool { isDigit(c) || (65...90).contains(c) || (97...122).contains(c) }
        let standard = body.allSatisfy { isLetterOrDigit($0) || $0 == UInt8(ascii: "+") || $0 == UInt8(ascii: "/") }
        let urlSafe = body.allSatisfy { isLetterOrDigit($0) || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_") }
        guard standard || urlSafe else { return nil }
        var normalized = String(decoding: body, as: UTF8.self)
        if !standard {
            normalized = normalized.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        }
        normalized += String(repeating: "=", count: (4 - normalized.utf8.count % 4) % 4)
        return Data(base64Encoded: normalized).map { [UInt8]($0) }
    }

    /// 标准字母表，带 `=` 补齐，不换行。
    public static func base64(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
    }
}
