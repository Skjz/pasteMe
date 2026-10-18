import Foundation

/// 转换卡片内容（#27）。结果作为一个新条目记录到历史最前面，原条目不变。
public enum TextConversion: String, CaseIterable, Sendable {
    /// 任意文本：把文本的 UTF-8 字节编码成 Base64。
    case encodeBase64
    /// Base64、hex、hexdump：字节按 UTF-8 解码成文字（ASCII 是 UTF-8 的子集，中文等也能正确显示）。
    case text
    case hex
    case hexdump
    case cArray
    /// 时间戳：本地时间，例如 `2025-10-17 16:00:00 GMT+8`。
    case localTime
    /// 时间戳：ISO 8601（UTC），例如 `2025-10-17T08:00:00Z`。
    case iso8601

    /// 菜单里的名字。`subtype` 是条目的子类型：Base64 的「文本」叫「解码」。
    public func title(for subtype: TextSubtype?) -> String {
        switch self {
        case .encodeBase64: "编码为 Base64"
        case .text: subtype == .base64 ? "解码" : "ASCII 文本"
        case .hex: "hex"
        case .hexdump: "hexdump"
        case .cArray: "C 数组"
        case .localTime: "本地时间"
        case .iso8601: "ISO 8601（UTC）"
        }
    }
}

/// 条目可以做的一种转换。做不了时 `unavailableReason` 说明原因，菜单里照样列出来、但不能选。
public struct ConversionOption: Equatable, Sendable {
    public var conversion: TextConversion
    public var unavailableReason: String?
}

public enum TextConverter {
    /// 超过这么多字节的内容不提供转换，面板不能卡住。和识别子类型的上限一样。
    public static let maxLength = TextSubtype.maxLength

    /// 按条目的子类型列出可以做的转换：子类型自己的转换在前，「编码为 Base64」在最后。内容太长时为空。
    ///
    /// | 子类型 | 可以转换为 |
    /// | --- | --- |
    /// | Base64 | 解码后的文本；不是 UTF-8 文本时改为 hex、hexdump |
    /// | hex | ASCII 文本、hexdump、C 数组 |
    /// | hexdump | ASCII 文本、hex、C 数组 |
    /// | 时间戳 | 本地时间、ISO 8601（UTC） |
    public static func options(for text: String, subtype: TextSubtype?) -> [ConversionOption] {
        guard text.utf8.count <= maxLength else { return [] }
        var options: [ConversionOption] = []
        switch subtype {
        case .base64:
            if let bytes = bytes(of: text, subtype: subtype), String(bytes: bytes, encoding: .utf8) != nil {
                options = [ConversionOption(conversion: .text)]
            } else {
                options = [ConversionOption(conversion: .hex), ConversionOption(conversion: .hexdump)]
            }
        case .hex, .hexdump:
            let isText = bytes(of: text, subtype: subtype).flatMap { String(bytes: $0, encoding: .utf8) } != nil
            options = [
                ConversionOption(conversion: .text, unavailableReason: isText ? nil : "字节不是合法的 UTF-8"),
                ConversionOption(conversion: subtype == .hex ? .hexdump : .hex),
                ConversionOption(conversion: .cArray),
            ]
        case .timestamp:
            options = [ConversionOption(conversion: .localTime), ConversionOption(conversion: .iso8601)]
        case .color, .code, nil:
            break
        }
        return options + [ConversionOption(conversion: .encodeBase64)]
    }

    /// 做一次转换，做不了时为 nil。
    public static func convert(
        _ text: String,
        subtype: TextSubtype?,
        using conversion: TextConversion,
        timeZone: TimeZone = .current
    ) -> String? {
        guard text.utf8.count <= maxLength else { return nil }
        switch conversion {
        case .encodeBase64:
            return ByteText.base64(Array(text.utf8))
        case .text:
            return bytes(of: text, subtype: subtype).flatMap { String(bytes: $0, encoding: .utf8) }
        case .hex:
            return bytes(of: text, subtype: subtype).map(ByteText.hex)
        case .hexdump:
            return bytes(of: text, subtype: subtype).map(ByteText.hexdump)
        case .cArray:
            return bytes(of: text, subtype: subtype).map { ByteText.cArray($0) }
        case .localTime:
            return UnixTimestamp.parse(text).map { TimestampText.local($0, timeZone: timeZone) }
        case .iso8601:
            return UnixTimestamp.parse(text).map(TimestampText.iso8601)
        }
    }

    /// Base64、hex、hexdump 条目代表的字节。
    static func bytes(of text: String, subtype: TextSubtype?) -> [UInt8]? {
        switch subtype {
        case .base64: ByteText.fromBase64(text)
        case .hex: ByteText.fromHex(text)
        case .hexdump: ByteText.fromHexdump(text)
        default: nil
        }
    }
}

/// 时间戳换算出的时间的几种写法。有不到一秒的部分时（毫秒时间戳、带小数的秒）写到毫秒。
public enum TimestampText {
    /// 本地时间和时区，例如 `2025-10-17 16:00:00 GMT+8`、`2025-10-17 16:00:00.123 GMT+8`。
    public static func local(_ date: Date, timeZone: TimeZone = .current) -> String {
        format(date, timeZone: timeZone, separator: " ") + " " + gmtOffset(of: date, in: timeZone)
    }

    /// ISO 8601，UTC，例如 `2025-10-17T08:00:00Z`。
    public static func iso8601(_ date: Date) -> String {
        format(date, timeZone: TimeZone(identifier: "UTC")!, separator: "T") + "Z"
    }

    /// 卡片每次画都要用，所以不用 `DateFormatter`（建一个要几十微秒），直接取日历分量。
    private static func format(_ date: Date, timeZone: TimeZone, separator: String) -> String {
        // 先按毫秒取整：0.123 在二进制里是 0.12299…，不取整会显示成 .122。
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        let wholeSeconds = Date(timeIntervalSince1970: (milliseconds / 1000).rounded(.down))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: wholeSeconds)
        var text = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!) + separator
            + String(format: "%02d:%02d:%02d", c.hour!, c.minute!, c.second!)
        let fraction = Int(milliseconds.truncatingRemainder(dividingBy: 1000))
        if fraction != 0 { text += String(format: ".%03d", fraction) }
        return text
    }

    /// `GMT+8`、`GMT+5:30`、`GMT-3`，零时区为 `GMT`。
    static func gmtOffset(of date: Date, in timeZone: TimeZone) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        guard seconds != 0 else { return "GMT" }
        let sign = seconds > 0 ? "+" : "-"
        let hours = abs(seconds) / 3600
        let minutes = abs(seconds) % 3600 / 60
        return "GMT" + sign + String(hours) + (minutes == 0 ? "" : String(format: ":%02d", minutes))
    }
}
