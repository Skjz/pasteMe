import Foundation

/// 在历史里查找条目的条件，交给 `ClipStore.items(matching:)`。
///
/// 怎样把条件变成 SQL（搜索哪些列、如何转义）都在这个文件里；以后增加筛选条件只改这里。
/// 所有条件同时满足的条目才会返回。
public struct ClipQuery: Sendable, Equatable {
    /// 只返回文本、图片中的文字或来源应用名包含这段文字的条目（子串匹配，不区分 ASCII 大小写）。
    /// 去掉首尾空白后为空时不按文字筛选。
    public var text: String
    /// 只返回这几种类型的条目。nil 表示不限类型；空集合表示什么都不返回（例如两个类型条件没有交集）。
    public var kinds: Set<ClipKind>?
    /// 只返回来自这个应用（bundle id）的条目。
    public var sourceBundleID: String?
    /// 只返回来源应用名包含这段文字的条目，来自搜索框里的 `app:`。
    public var sourceName: String?
    /// 只返回这个时间及以后复制的条目。
    public var createdFrom: Date?
    /// 只返回这个时间以前复制的条目（不含这个时间）。
    public var createdBefore: Date?
    /// 最多返回多少条。
    public var limit: Int

    public init(
        text: String = "",
        kinds: Set<ClipKind>? = nil,
        sourceBundleID: String? = nil,
        sourceName: String? = nil,
        createdFrom: Date? = nil,
        createdBefore: Date? = nil,
        limit: Int = 200
    ) {
        self.text = text
        self.kinds = kinds
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.createdFrom = createdFrom
        self.createdBefore = createdBefore
        self.limit = limit
    }

    /// 再加一个类型条件，结果是两个条件的交集。
    public func restricting(to kinds: Set<ClipKind>?) -> ClipQuery {
        guard let kinds else { return self }
        var query = self
        query.kinds = self.kinds.map { $0.intersection(kinds) } ?? kinds
        return query
    }

    /// 解析搜索框里的文字：`type:图片`、`app:微信` 这样的词变成筛选条件，其余的词作为搜索文字。
    ///
    /// - `type:`（或 `类型:`）后面写类型的中文或英文名，只写开头几个字母也可以，比如 `type:im`。
    ///   写了几个时取并集；认不出来的词按普通文字搜索。
    /// - `app:`（或 `应用:`）后面写来源应用名的一部分。
    /// - 冒号用全角的“：”也可以，中文输入法下不用切换。
    public static func parse(_ input: String, limit: Int = 200) -> ClipQuery {
        var query = ClipQuery(limit: limit)
        var words: [Substring] = []
        var kinds: Set<ClipKind> = []
        var apps: [String] = []

        for word in input.split(whereSeparator: \.isWhitespace) {
            guard let colon = word.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
                words.append(word)
                continue
            }
            let key = word[..<colon].lowercased()
            let value = String(word[word.index(after: colon)...])
            switch key {
            case "type", "类型":
                // 还没写值时（刚输入完冒号）先不筛选，也不按文字搜索。
                guard !value.isEmpty else { continue }
                let matched = ClipKind.allCases.filter { $0.matchesSearchName(value) }
                if matched.isEmpty { words.append(word) } else { kinds.formUnion(matched) }
            case "app", "应用":
                if !value.isEmpty { apps.append(value) }
            default:
                words.append(word)
            }
        }

        query.text = words.joined(separator: " ")
        if !kinds.isEmpty { query.kinds = kinds }
        // 写了几个 app: 时只用最后一个：同一条目不可能来自两个应用。
        query.sourceName = apps.last
        return query
    }
}

/// 面板的时间筛选。
public enum TimeRange: String, CaseIterable, Sendable {
    case all
    case today
    case yesterday
    /// 今天和之前的 6 天。
    case last7Days
    /// 今天和之前的 29 天。
    case last30Days

    /// 这个时间段的起止时间（含起点、不含终点），按 `calendar` 的时区划分日期。
    public func bounds(now: Date = Date(), calendar: Calendar = .current) -> (from: Date?, before: Date?) {
        let today = calendar.startOfDay(for: now)
        func daysAgo(_ days: Int) -> Date { calendar.date(byAdding: .day, value: -days, to: today)! }
        switch self {
        case .all: return (nil, nil)
        case .today: return (today, nil)
        case .yesterday: return (daysAgo(1), today)
        case .last7Days: return (daysAgo(6), nil)
        case .last30Days: return (daysAgo(29), nil)
        }
    }
}

extension ClipKind {
    /// 搜索框里 `type:` 后面可以写的名字。
    var searchNames: [String] {
        switch self {
        case .text: ["text", "文本", "文字"]
        case .link: ["link", "url", "链接", "网址"]
        case .image: ["image", "图片", "截图"]
        case .file: ["file", "文件"]
        }
    }

    func matchesSearchName(_ value: String) -> Bool {
        let value = value.lowercased()
        return searchNames.contains { $0.hasPrefix(value) }
    }
}

extension ClipQuery {
    /// `WHERE` 子句（不含 `WHERE` 关键字，没有条件时为 nil）及其参数。
    var filter: (clause: String, values: [SQLValue])? {
        var clauses: [String] = []
        var values: [SQLValue] = []

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // 搜索用 LIKE 子串匹配而不是 FTS5，原因见 ADR 0004。
            let pattern = SQLValue.text("%" + Self.escapeLike(trimmed) + "%")
            clauses.append("(text LIKE ? ESCAPE '\\' OR ocr_text LIKE ? ESCAPE '\\' OR source_name LIKE ? ESCAPE '\\')")
            values += [pattern, pattern, pattern]
        }
        if let kinds {
            if kinds.isEmpty {
                clauses.append("(0)")
            } else {
                let sorted = kinds.map(\.rawValue).sorted()
                clauses.append("(kind IN (\(sorted.map { _ in "?" }.joined(separator: ", "))))")
                values += sorted.map(SQLValue.text)
            }
        }
        if let sourceBundleID {
            clauses.append("(source_bundle_id = ?)")
            values.append(.text(sourceBundleID))
        }
        if let sourceName {
            clauses.append("(source_name LIKE ? ESCAPE '\\')")
            values.append(.text("%" + Self.escapeLike(sourceName) + "%"))
        }
        if let createdFrom {
            clauses.append("(created_at >= ?)")
            values.append(.double(createdFrom.timeIntervalSince1970))
        }
        if let createdBefore {
            clauses.append("(created_at < ?)")
            values.append(.double(createdBefore.timeIntervalSince1970))
        }

        guard !clauses.isEmpty else { return nil }
        return (clauses.joined(separator: " AND "), values)
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
