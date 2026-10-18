import Foundation

/// 文本子类型（#26、#28）：类型为文本的条目，按内容进一步识别出的种类。
///
/// 不是新的类型：类型决定卡片的展示方式和粘贴时写回什么，而这些内容粘贴时和普通文本一样，
/// 按「文本」筛选时也包含它们。记录时由 `detect` 算一次，存在 `clips.text_subtype` 里。
public enum TextSubtype: Hashable, Sendable {
    case color
    case timestamp
    case hexdump
    case hex
    case base64
    case code(CodeLanguage)

    /// 超过这么多字节的文本不识别，免得记录时卡住。
    public static let maxLength = 1_000_000

    /// 存进数据库的写法，例如 `base64`、`code:swift`。
    public var rawValue: String {
        switch self {
        case .code(let language): "code:" + language.rawValue
        default: category.rawValue
        }
    }

    public init?(rawValue: String) {
        if rawValue.hasPrefix("code:") {
            guard let language = CodeLanguage(rawValue: String(rawValue.dropFirst(5))) else { return nil }
            self = .code(language)
            return
        }
        switch Category(rawValue: rawValue) {
        case .color: self = .color
        case .timestamp: self = .timestamp
        case .hexdump: self = .hexdump
        case .hex: self = .hex
        case .base64: self = .base64
        case .code, nil: return nil
        }
    }

    public var category: Category {
        switch self {
        case .color: .color
        case .timestamp: .timestamp
        case .hexdump: .hexdump
        case .hex: .hex
        case .base64: .base64
        case .code: .code
        }
    }

    /// 卡片标题栏里类型名后面的部分，例如「文本 · Base64」里的「Base64」、「文本 · Swift」里的「Swift」。
    public var title: String {
        switch self {
        case .code(let language): language.title
        default: category.title
        }
    }

    /// 按子类型筛选时的分组：代码不分语言。
    public enum Category: String, CaseIterable, Sendable {
        case color
        case timestamp
        case hexdump
        case hex
        case base64
        case code

        public var title: String {
            switch self {
            case .color: "颜色"
            case .timestamp: "时间戳"
            case .hexdump: "hexdump"
            case .hex: "hex"
            case .base64: "Base64"
            case .code: "代码"
            }
        }

        /// 搜索框里 `@` 和 `type:` 后面可以写的名字。
        var searchNames: [String] {
            switch self {
            case .color: ["color", "颜色"]
            case .timestamp: ["timestamp", "时间戳"]
            case .hexdump: ["hexdump", "xxd"]
            case .hex: ["hex", "十六进制"]
            case .base64: ["base64"]
            case .code: ["code", "代码"]
            }
        }

        func matchesSearchName(_ value: String) -> Bool {
            let value = value.lowercased()
            return searchNames.contains { $0.hasPrefix(value) }
        }

        /// 名字以 `value` 开头的子类型，`value` 为空时返回全部。
        public static func matching(_ value: String) -> [Category] {
            allCases.filter { $0.matchesSearchName(value) }
        }
    }

    /// 识别整段文本（去掉首尾空白后）是哪种子类型，都不是时为 nil。长段落里夹着的一小段不算。
    ///
    /// 同时符合几种时按 颜色 > 时间戳 > hexdump > hex > Base64 > 代码 的顺序取第一个。
    /// `sourceBundleID` 是复制时的应用：从编辑器和终端复制的内容，判断为代码的门槛低一些。
    public static func detect(_ text: String, sourceBundleID: String? = nil) -> TextSubtype? {
        guard text.utf8.count <= maxLength else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if ColorValue.parse(trimmed) != nil { return .color }
        if UnixTimestamp.parse(trimmed) != nil { return .timestamp }
        if ByteText.fromHexdump(trimmed) != nil { return .hexdump }
        if ByteText.fromHex(trimmed) != nil { return .hex }
        if looksLikeBase64(trimmed) { return .base64 }
        if let language = CodeDetector.language(of: text, sourceBundleID: sourceBundleID) { return .code(language) }
        return nil
    }

    /// 能按 Base64 解码，而且不像普通的词、标识符或路径：解码出来是可以显示的 UTF-8 文字，
    /// 或者至少 16 个字符、大小写字母和数字都有、而且不像驼峰命名（见 `looksCamelCase`）。
    /// `function`、`myVariableName2024` 这样的词本身也是合法的 Base64，要排除。
    static func looksLikeBase64(_ text: String) -> Bool {
        guard text.utf8.count >= 8, let bytes = ByteText.fromBase64(text) else { return false }
        let characters = text.utf8.filter { $0 != UInt8(ascii: "\n") && $0 != UInt8(ascii: "\r") }
        guard !characters.allSatisfy(ByteText.isDigit) else { return false }
        if let decoded = String(bytes: bytes, encoding: .utf8), decoded.utf8.count >= 3,
           decoded.unicodeScalars.allSatisfy(isPrintable) {
            return true
        }
        let hasUpper = characters.contains { (65...90).contains($0) }
        let hasLower = characters.contains { (97...122).contains($0) }
        let hasDigit = characters.contains(where: ByteText.isDigit)
        guard characters.count >= 16, hasUpper, hasLower, hasDigit else { return false }
        return !looksCamelCase(characters)
    }

    /// 驼峰命名的标识符（`SomeClassName123`）里，大写字母后面几乎总是小写字母；随机的 Base64 里只有四成左右。
    /// 大写字母少于两个时看不出来，也按驼峰命名算。
    private static func looksCamelCase(_ characters: [UInt8]) -> Bool {
        var uppercase = 0
        var followedByLowercase = 0
        for (index, c) in characters.enumerated() where (65...90).contains(c) {
            uppercase += 1
            if index + 1 < characters.count, (97...122).contains(characters[index + 1]) {
                followedByLowercase += 1
            }
        }
        return uppercase < 2 || Double(followedByLowercase) / Double(uppercase) >= 0.7
    }

    private static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\n" || scalar == "\r" || scalar == "\t" { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .unassigned, .privateUse, .surrogate: return false
        default: return true
        }
    }
}
