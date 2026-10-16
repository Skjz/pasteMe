import Foundation

/// 在历史里查找条目的条件，交给 `ClipStore.items(matching:)`。
///
/// 怎样把条件变成 SQL（搜索哪些列、如何转义）都在这个文件里；以后增加筛选条件只改这里。
public struct ClipQuery: Sendable, Equatable {
    /// 只返回文本或来源应用名包含这段文字的条目（子串匹配，不区分 ASCII 大小写）。
    /// 去掉首尾空白后为空时不按文字筛选。
    public var text: String
    /// 最多返回多少条。
    public var limit: Int

    public init(text: String = "", limit: Int = 200) {
        self.text = text
        self.limit = limit
    }
}

extension ClipQuery {
    /// `WHERE` 子句（不含 `WHERE` 关键字，没有条件时为 nil）及其参数。
    var filter: (clause: String, values: [SQLValue])? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 搜索用 LIKE 子串匹配而不是 FTS5，原因见 ADR 0004。
        let pattern = SQLValue.text("%" + Self.escapeLike(trimmed) + "%")
        return ("(text LIKE ? ESCAPE '\\' OR source_name LIKE ? ESCAPE '\\')", [pattern, pattern])
    }

    static func escapeLike(_ string: String) -> String {
        var escaped = ""
        for char in string {
            if char == "\\" || char == "%" || char == "_" { escaped.append("\\") }
            escaped.append(char)
        }
        return escaped
    }
}
