import Foundation

/// 按词法给代码着色（#28），不做语义分析：关键字、字符串、数字、注释、类型名、函数调用、注解和属性。
///
/// 多数语言共用一套 C 风格的规则（`Lexer`），只换关键字表、注释和字符串的写法；
/// HTML/XML、CSS、JSON、YAML 各有自己的规则。结果是覆盖整段文字的片段，没着色的部分 `kind` 为 nil。
public enum SyntaxHighlighter {
    public enum Kind: Sendable, Equatable {
        case keyword
        case string
        case number
        case comment
        case type
        case function
        /// `@State`、`#[derive]`、Python 的装饰器、YAML 的锚点。
        case attribute
        /// JSON、YAML 的键，CSS 的属性名，HTML 的属性名。
        case property
        /// Shell、PHP 的 `$变量`，Ruby 的 `@变量`。
        case variable
        /// HTML、XML 的标签名。
        case tag
    }

    public struct Segment: Equatable, Sendable {
        public var text: String
        public var kind: Kind?

        public init(_ text: String, _ kind: Kind?) {
            self.text = text
            self.kind = kind
        }
    }

    public static func segments(of text: String, language: CodeLanguage) -> [Segment] {
        let bytes = Array(text.utf8)
        var tokens = Tokens(bytes: bytes)
        switch language {
        case .html, .xml: highlightMarkup(&tokens)
        case .css: highlightCSS(&tokens)
        case .json: highlightJSON(&tokens)
        case .yaml: highlightYAML(&tokens)
        default: Lexer(rules: LexerRules.rules(for: language), tokens: tokens).run(into: &tokens)
        }
        return tokens.segments()
    }

    // MARK: - 结果

    /// 按位置记下的着色范围（UTF-8 字节），最后切成片段。
    struct Tokens {
        let bytes: [UInt8]
        private(set) var marks: [(range: Range<Int>, kind: Kind)] = []

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func mark(_ range: Range<Int>, _ kind: Kind) {
            guard !range.isEmpty else { return }
            marks.append((range, kind))
        }

        func segments() -> [Segment] {
            var result: [Segment] = []
            var position = 0
            func append(_ range: Range<Int>, _ kind: Kind?) {
                guard !range.isEmpty else { return }
                let text = String(decoding: bytes[range], as: UTF8.self)
                if let last = result.last, last.kind == kind {
                    result[result.count - 1].text += text
                } else {
                    result.append(Segment(text, kind))
                }
            }
            for mark in marks.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) where mark.range.lowerBound >= position {
                append(position..<mark.range.lowerBound, nil)
                append(mark.range, mark.kind)
                position = mark.range.upperBound
            }
            append(position..<bytes.count, nil)
            return result
        }
    }

    // MARK: - 字符

    static func isIdentifierStart(_ c: UInt8) -> Bool {
        (65...90).contains(c) || (97...122).contains(c) || c == UInt8(ascii: "_")
    }

    static func isIdentifierPart(_ c: UInt8) -> Bool {
        isIdentifierStart(c) || (48...57).contains(c)
    }

    static func isDigit(_ c: UInt8) -> Bool { (48...57).contains(c) }

    static func isSpace(_ c: UInt8) -> Bool {
        c == UInt8(ascii: " ") || c == UInt8(ascii: "\t") || c == UInt8(ascii: "\r")
    }

    static func starts(_ bytes: [UInt8], at index: Int, with prefix: [UInt8]) -> Bool {
        index + prefix.count <= bytes.count && bytes[index..<(index + prefix.count)].elementsEqual(prefix)
    }

    /// 从 `start` 开始的数字：`42`、`3.14`、`1_000`、`0xff`、`1e-9`、`10px`、`2.5f`。
    static func numberEnd(_ bytes: [UInt8], from start: Int) -> Int {
        var i = start
        if starts(bytes, at: i, with: Array("0x".utf8)) || starts(bytes, at: i, with: Array("0b".utf8))
            || starts(bytes, at: i, with: Array("0o".utf8)) {
            i += 2
        }
        while i < bytes.count {
            let c = bytes[i]
            if isIdentifierPart(c) {
                // 指数里的正负号：1e-9。
                if (c == UInt8(ascii: "e") || c == UInt8(ascii: "E")), i + 1 < bytes.count,
                   bytes[i + 1] == UInt8(ascii: "-") || bytes[i + 1] == UInt8(ascii: "+") {
                    i += 2
                    continue
                }
                i += 1
            } else if c == UInt8(ascii: "."), i + 1 < bytes.count, isDigit(bytes[i + 1]) {
                i += 1
            } else {
                break
            }
        }
        return i
    }
}

// MARK: - C 风格的通用规则

/// 一种语言的词法：注释、字符串的写法和关键字表。
struct LexerRules {
    var lineComments: [[UInt8]] = [Array("//".utf8)]
    var blockComments: [(open: [UInt8], close: [UInt8])] = [(Array("/*".utf8), Array("*/".utf8))]
    /// `#` 注释只在词首才算（Shell 的 `${#array}`、URL 里的 `#` 不是注释）。
    var hashCommentsAtWordStart = false
    /// 长的写在前面：`"""` 要先于 `"` 匹配。
    var stringDelimiters: [[UInt8]] = [Array("\"".utf8), Array("'".utf8)]
    /// 可以跨行的字符串。
    var multilineDelimiters: Set<[UInt8]> = []
    var keywords: Set<String> = []
    var builtinTypes: Set<String> = []
    /// 关键字不分大小写（SQL）。表里写小写。
    var caseInsensitive = false
    /// 首字母大写的标识符当成类型名。
    var capitalizedAreTypes = true
    /// `@名字` 的颜色：Swift、Java、Kotlin、Python 是注解，Ruby 是实例变量。nil 表示 `@` 没有特别含义。
    var atPrefix: SyntaxHighlighter.Kind?
    /// `$名字` 是变量（Shell、PHP）。
    var dollarVariables = false
    /// 行首的 `#include` 这样的预处理指令（C 一族）。
    var preprocessor = false
    /// `'a` 是生命周期，不是字符（Rust）。
    var lifetimes = false
    /// 标识符后面紧跟 `!(` 是宏调用（Rust 的 `println!`）。
    var macros = false

    static func rules(for language: CodeLanguage) -> LexerRules {
        var rules = LexerRules()
        switch language {
        case .swift:
            rules.stringDelimiters = [Array("\"\"\"".utf8), Array("\"".utf8)]
            rules.multilineDelimiters = [Array("\"\"\"".utf8)]
            rules.keywords = Keywords.swift
            rules.atPrefix = .attribute
            rules.preprocessor = true
        case .objectiveC:
            rules.keywords = Keywords.c.union(Keywords.objectiveC)
            rules.builtinTypes = Keywords.cTypes
            rules.atPrefix = .keyword
            rules.preprocessor = true
        case .c:
            rules.keywords = Keywords.c
            rules.builtinTypes = Keywords.cTypes
            rules.preprocessor = true
        case .cpp:
            rules.keywords = Keywords.c.union(Keywords.cpp)
            rules.builtinTypes = Keywords.cTypes
            rules.preprocessor = true
        case .csharp:
            rules.keywords = Keywords.csharp
            rules.stringDelimiters = [Array("\"\"\"".utf8), Array("\"".utf8), Array("'".utf8)]
            rules.multilineDelimiters = [Array("\"\"\"".utf8)]
            rules.preprocessor = true
        case .java:
            rules.keywords = Keywords.java
            rules.stringDelimiters = [Array("\"\"\"".utf8), Array("\"".utf8), Array("'".utf8)]
            rules.multilineDelimiters = [Array("\"\"\"".utf8)]
            rules.atPrefix = .attribute
        case .kotlin:
            rules.keywords = Keywords.kotlin
            rules.stringDelimiters = [Array("\"\"\"".utf8), Array("\"".utf8), Array("'".utf8)]
            rules.multilineDelimiters = [Array("\"\"\"".utf8)]
            rules.atPrefix = .attribute
        case .go:
            rules.keywords = Keywords.go
            rules.builtinTypes = Keywords.goTypes
            rules.stringDelimiters = [Array("`".utf8), Array("\"".utf8), Array("'".utf8)]
            rules.multilineDelimiters = [Array("`".utf8)]
            rules.capitalizedAreTypes = false
        case .rust:
            rules.keywords = Keywords.rust
            rules.builtinTypes = Keywords.rustTypes
            rules.lifetimes = true
            rules.macros = true
            rules.stringDelimiters = [Array("\"".utf8), Array("'".utf8)]
            rules.multilineDelimiters = [Array("\"".utf8)]
        case .javascript, .typescript:
            rules.keywords = language == .typescript ? Keywords.javascript.union(Keywords.typescript) : Keywords.javascript
            rules.builtinTypes = language == .typescript ? Keywords.typescriptTypes : []
            rules.stringDelimiters = [Array("`".utf8), Array("\"".utf8), Array("'".utf8)]
            rules.multilineDelimiters = [Array("`".utf8)]
            rules.atPrefix = .attribute
        case .python:
            rules.lineComments = [Array("#".utf8)]
            rules.blockComments = []
            rules.hashCommentsAtWordStart = true
            rules.stringDelimiters = [Array("\"\"\"".utf8), Array("'''".utf8), Array("\"".utf8), Array("'".utf8)]
            rules.multilineDelimiters = [Array("\"\"\"".utf8), Array("'''".utf8)]
            rules.keywords = Keywords.python
            rules.builtinTypes = Keywords.pythonTypes
            rules.atPrefix = .attribute
        case .ruby:
            rules.lineComments = [Array("#".utf8)]
            rules.blockComments = []
            rules.hashCommentsAtWordStart = true
            rules.keywords = Keywords.ruby
            rules.atPrefix = .variable
        case .php:
            rules.lineComments = [Array("//".utf8), Array("#".utf8)]
            rules.hashCommentsAtWordStart = true
            rules.keywords = Keywords.php
            rules.dollarVariables = true
        case .shell:
            rules.lineComments = [Array("#".utf8)]
            rules.blockComments = []
            rules.hashCommentsAtWordStart = true
            rules.keywords = Keywords.shell
            rules.dollarVariables = true
            rules.capitalizedAreTypes = false
            rules.multilineDelimiters = [Array("\"".utf8), Array("'".utf8)]
        case .sql:
            rules.lineComments = [Array("--".utf8)]
            rules.keywords = Keywords.sql
            rules.builtinTypes = Keywords.sqlTypes
            rules.caseInsensitive = true
            rules.capitalizedAreTypes = false
        case .html, .xml, .css, .json, .yaml:
            break
        }
        return rules
    }
}

/// C 风格的词法扫描：注释、字符串、数字、标识符（关键字、类型名、函数调用、注解、变量）。
struct Lexer {
    let rules: LexerRules
    let bytes: [UInt8]

    init(rules: LexerRules, tokens: SyntaxHighlighter.Tokens) {
        self.rules = rules
        bytes = tokens.bytes
    }

    typealias H = SyntaxHighlighter

    func run(into tokens: inout SyntaxHighlighter.Tokens) {
        var i = 0
        var lineStart = true
        while i < bytes.count {
            let c = bytes[i]
            if c == UInt8(ascii: "\n") {
                lineStart = true
                i += 1
                continue
            }
            if H.isSpace(c) {
                i += 1
                continue
            }
            let atLineStart = lineStart
            lineStart = false

            if let end = comment(at: i) {
                tokens.mark(i..<end, .comment)
                i = end
                continue
            }
            if rules.preprocessor, atLineStart, c == UInt8(ascii: "#") {
                let end = identifierEnd(from: i + 1)
                tokens.mark(i..<end, .keyword)
                i = end
                // `#include <stdio.h>` 里的 `<…>` 当成字符串。
                var j = i
                while j < bytes.count, H.isSpace(bytes[j]) { j += 1 }
                if j < bytes.count, bytes[j] == UInt8(ascii: "<"), let close = bytes[j...].firstIndex(of: UInt8(ascii: ">")),
                   !bytes[j..<close].contains(UInt8(ascii: "\n")) {
                    tokens.mark(j..<(close + 1), .string)
                    i = close + 1
                }
                continue
            }
            if rules.lifetimes, c == UInt8(ascii: "'"), isLifetime(at: i) {
                let end = identifierEnd(from: i + 1)
                tokens.mark(i..<end, .attribute)
                i = end
                continue
            }
            if let end = string(at: i) {
                tokens.mark(i..<end, .string)
                i = end
                continue
            }
            if H.isDigit(c), i == 0 || !H.isIdentifierPart(bytes[i - 1]) {
                let end = H.numberEnd(bytes, from: i)
                tokens.mark(i..<end, .number)
                i = end
                continue
            }
            if c == UInt8(ascii: "@"), let kind = rules.atPrefix, i + 1 < bytes.count, H.isIdentifierStart(bytes[i + 1]) {
                let end = identifierEnd(from: i + 1)
                let word = String(decoding: bytes[(i + 1)..<end], as: UTF8.self)
                tokens.mark(i..<end, kind == .keyword || rules.keywords.contains(word) && kind != .variable ? .keyword : kind)
                i = end
                continue
            }
            if c == UInt8(ascii: "$"), rules.dollarVariables {
                let end = variableEnd(from: i)
                tokens.mark(i..<end, .variable)
                i = max(end, i + 1)
                continue
            }
            if H.isIdentifierStart(c) {
                let end = identifierEnd(from: i)
                if let kind = classify(i..<end) {
                    var markEnd = end
                    // Rust 的宏：`println!(`。
                    if rules.macros, end < bytes.count, bytes[end] == UInt8(ascii: "!") { markEnd = end + 1 }
                    tokens.mark(i..<markEnd, kind)
                }
                i = end
                continue
            }
            i += 1
        }
    }

    private func identifierEnd(from start: Int) -> Int {
        var end = start
        while end < bytes.count, H.isIdentifierPart(bytes[end]) { end += 1 }
        return end
    }

    /// `$NAME`、`${NAME}`、`$1`、`$@`；`$(` 只标出 `$`。
    private func variableEnd(from start: Int) -> Int {
        let next = start + 1
        guard next < bytes.count else { return next }
        if bytes[next] == UInt8(ascii: "{"), let close = bytes[next...].firstIndex(of: UInt8(ascii: "}")) {
            return close + 1
        }
        if H.isIdentifierStart(bytes[next]) { return identifierEnd(from: next) }
        if H.isDigit(bytes[next]) || "@#?*!".utf8.contains(bytes[next]) { return next + 1 }
        return next
    }

    private func classify(_ range: Range<Int>) -> SyntaxHighlighter.Kind? {
        let word = String(decoding: bytes[range], as: UTF8.self)
        let key = rules.caseInsensitive ? word.lowercased() : word
        if rules.keywords.contains(key) { return .keyword }
        if rules.builtinTypes.contains(key) { return .type }
        var next = range.upperBound
        if rules.macros, next < bytes.count, bytes[next] == UInt8(ascii: "!") { next += 1 }
        let followedByParen = next < bytes.count && bytes[next] == UInt8(ascii: "(")
        // 首字母大写的是类型名（`URL`、`UUID` 这样的缩写也算），带下划线的全大写名字（`MAX_SIZE`）是常量。
        if rules.capitalizedAreTypes, let first = bytes[range].first, (65...90).contains(first),
           bytes[range].contains(where: { (97...122).contains($0) }) || !bytes[range].contains(UInt8(ascii: "_")) {
            return .type
        }
        return followedByParen ? .function : nil
    }

    private func comment(at i: Int) -> Int? {
        for marker in rules.lineComments where H.starts(bytes, at: i, with: marker) {
            if marker == Array("#".utf8), rules.hashCommentsAtWordStart, i > 0, !H.isSpace(bytes[i - 1]), bytes[i - 1] != UInt8(ascii: "\n") {
                continue
            }
            return bytes[i...].firstIndex(of: UInt8(ascii: "\n")) ?? bytes.count
        }
        for (open, close) in rules.blockComments where H.starts(bytes, at: i, with: open) {
            var j = i + open.count
            while j < bytes.count, !H.starts(bytes, at: j, with: close) { j += 1 }
            return min(j + close.count, bytes.count)
        }
        return nil
    }

    private func string(at i: Int) -> Int? {
        for delimiter in rules.stringDelimiters where H.starts(bytes, at: i, with: delimiter) {
            let multiline = rules.multilineDelimiters.contains(delimiter)
            var j = i + delimiter.count
            while j < bytes.count {
                if bytes[j] == UInt8(ascii: "\\") {
                    j += 2
                    continue
                }
                if H.starts(bytes, at: j, with: delimiter) { return j + delimiter.count }
                if bytes[j] == UInt8(ascii: "\n"), !multiline { return j }
                j += 1
            }
            return bytes.count
        }
        return nil
    }

    /// Rust 的 `'a`：引号后是标识符，而且隔一个字符后不是引号（`'a'` 是字符）。
    private func isLifetime(at i: Int) -> Bool {
        guard i + 1 < bytes.count, H.isIdentifierStart(bytes[i + 1]) else { return false }
        return !(i + 2 < bytes.count && bytes[i + 2] == UInt8(ascii: "'"))
    }
}

// MARK: - HTML、XML

extension SyntaxHighlighter {
    /// 注释、`<?xml …?>` 和 `<!DOCTYPE …>`、标签名、属性名和属性值。标签之间的文字不着色。
    static func highlightMarkup(_ tokens: inout Tokens) {
        let bytes = tokens.bytes
        var i = 0
        while i < bytes.count {
            guard bytes[i] == UInt8(ascii: "<") else {
                i += 1
                continue
            }
            if starts(bytes, at: i, with: Array("<!--".utf8)) {
                var j = i + 4
                while j < bytes.count, !starts(bytes, at: j, with: Array("-->".utf8)) { j += 1 }
                let end = min(j + 3, bytes.count)
                tokens.mark(i..<end, .comment)
                i = end
                continue
            }
            if i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "?") || bytes[i + 1] == UInt8(ascii: "!") {
                let end = (bytes[i...].firstIndex(of: UInt8(ascii: ">")) ?? bytes.count - 1) + 1
                tokens.mark(i..<end, .keyword)
                i = end
                continue
            }
            var j = i + 1
            if j < bytes.count, bytes[j] == UInt8(ascii: "/") { j += 1 }
            let nameStart = j
            while j < bytes.count, isIdentifierPart(bytes[j]) || bytes[j] == UInt8(ascii: "-") || bytes[j] == UInt8(ascii: ":") {
                j += 1
            }
            guard j > nameStart else {
                i += 1
                continue
            }
            tokens.mark(nameStart..<j, .tag)
            // 属性，到 `>` 为止。
            while j < bytes.count, bytes[j] != UInt8(ascii: ">") {
                let c = bytes[j]
                if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                    let close = bytes[(j + 1)...].firstIndex(of: c) ?? bytes.count - 1
                    tokens.mark(j..<(close + 1), .string)
                    j = close + 1
                } else if isIdentifierStart(c) {
                    let start = j
                    while j < bytes.count, isIdentifierPart(bytes[j]) || bytes[j] == UInt8(ascii: "-") || bytes[j] == UInt8(ascii: ":") {
                        j += 1
                    }
                    tokens.mark(start..<j, .property)
                } else {
                    j += 1
                }
            }
            i = j
        }
    }

    // MARK: - CSS

    /// 注释、`@media` 这样的规则、选择器、属性名、值里的数字、颜色、字符串和函数，`!important`。
    static func highlightCSS(_ tokens: inout Tokens) {
        let bytes = tokens.bytes
        var i = 0
        var depth = 0
        // `@media (max-width: 600px)` 括号里的和声明一样。
        var parens = 0
        while i < bytes.count {
            let c = bytes[i]
            if starts(bytes, at: i, with: Array("/*".utf8)) {
                var j = i + 2
                while j < bytes.count, !starts(bytes, at: j, with: Array("*/".utf8)) { j += 1 }
                let end = min(j + 2, bytes.count)
                tokens.mark(i..<end, .comment)
                i = end
                continue
            }
            if c == UInt8(ascii: "{") { depth += 1 }
            if c == UInt8(ascii: "}") { depth = max(0, depth - 1) }
            if c == UInt8(ascii: "(") { parens += 1 }
            if c == UInt8(ascii: ")") { parens = max(0, parens - 1) }
            if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                let close = bytes[(i + 1)...].firstIndex(of: c) ?? bytes.count - 1
                tokens.mark(i..<(close + 1), .string)
                i = close + 1
                continue
            }
            if c == UInt8(ascii: "@") || c == UInt8(ascii: "!") {
                var j = i + 1
                while j < bytes.count, isIdentifierPart(bytes[j]) || bytes[j] == UInt8(ascii: "-") { j += 1 }
                tokens.mark(i..<j, .keyword)
                i = max(j, i + 1)
                continue
            }
            if depth > 0, c == UInt8(ascii: "#"), i + 1 < bytes.count, bytes[i + 1].isASCIIHexDigit {
                var j = i + 1
                while j < bytes.count, bytes[j].isASCIIHexDigit { j += 1 }
                tokens.mark(i..<j, .number)
                i = j
                continue
            }
            if isDigit(c) || (c == UInt8(ascii: ".") && i + 1 < bytes.count && isDigit(bytes[i + 1])),
               i == 0 || !isIdentifierPart(bytes[i - 1]) && bytes[i - 1] != UInt8(ascii: "-") || bytes[i - 1] == UInt8(ascii: " ") {
                var j = c == UInt8(ascii: ".") ? i + 1 : i
                j = numberEnd(bytes, from: j)
                if j < bytes.count, bytes[j] == UInt8(ascii: "%") { j += 1 }
                tokens.mark(i..<j, .number)
                i = j
                continue
            }
            if isIdentifierStart(c) || c == UInt8(ascii: "-") {
                var j = i
                while j < bytes.count, isIdentifierPart(bytes[j]) || bytes[j] == UInt8(ascii: "-") { j += 1 }
                guard j > i else {
                    i += 1
                    continue
                }
                // 看接下来先碰到 `{`（是选择器）还是 `;`、`}`（是声明）。
                var k = j
                while k < bytes.count, ![UInt8(ascii: "{"), UInt8(ascii: ";"), UInt8(ascii: "}")].contains(bytes[k]) { k += 1 }
                let isSelector = (depth == 0 && parens == 0) || (parens == 0 && k < bytes.count && bytes[k] == UInt8(ascii: "{"))
                var colon = j
                while colon < bytes.count, isSpace(bytes[colon]) { colon += 1 }
                if !isSelector, colon < bytes.count, bytes[colon] == UInt8(ascii: ":") {
                    tokens.mark(i..<j, .property)
                } else if !isSelector, j < bytes.count, bytes[j] == UInt8(ascii: "(") {
                    tokens.mark(i..<j, .function)
                } else if isSelector, i == 0 || ![UInt8(ascii: "."), UInt8(ascii: "#"), UInt8(ascii: ":")].contains(bytes[i - 1]) {
                    tokens.mark(i..<j, .tag)
                } else if isSelector {
                    tokens.mark((i - 1)..<j, .type)
                }
                i = j
                continue
            }
            i += 1
        }
    }

    // MARK: - JSON

    /// 键（字符串后面跟着冒号）、字符串、数字和 `true`、`false`、`null`。
    static func highlightJSON(_ tokens: inout Tokens) {
        let bytes = tokens.bytes
        var i = 0
        while i < bytes.count {
            let c = bytes[i]
            if c == UInt8(ascii: "\"") {
                var j = i + 1
                while j < bytes.count, bytes[j] != UInt8(ascii: "\"") {
                    j += bytes[j] == UInt8(ascii: "\\") ? 2 : 1
                }
                let end = min(j + 1, bytes.count)
                var k = end
                while k < bytes.count, isSpace(bytes[k]) || bytes[k] == UInt8(ascii: "\n") { k += 1 }
                tokens.mark(i..<end, k < bytes.count && bytes[k] == UInt8(ascii: ":") ? .property : .string)
                i = end
            } else if isDigit(c) || c == UInt8(ascii: "-") {
                let end = numberEnd(bytes, from: c == UInt8(ascii: "-") ? i + 1 : i)
                tokens.mark(i..<end, .number)
                i = max(end, i + 1)
            } else if isIdentifierStart(c) {
                var j = i
                while j < bytes.count, isIdentifierPart(bytes[j]) { j += 1 }
                tokens.mark(i..<j, .keyword)
                i = j
            } else {
                i += 1
            }
        }
    }

    // MARK: - YAML

    private static let yamlKeywords: Set<String> = ["true", "false", "yes", "no", "on", "off", "null", "~"]

    /// 逐行：注释、`---`、键、引号里的字符串、数字、布尔值和 null、`&锚点` 和 `*引用`。
    static func highlightYAML(_ tokens: inout Tokens) {
        let bytes = tokens.bytes
        var lineStart = 0
        while lineStart < bytes.count {
            let lineEnd = bytes[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? bytes.count
            var i = lineStart
            while i < lineEnd, isSpace(bytes[i]) { i += 1 }
            if starts(bytes, at: i, with: Array("---".utf8)) || starts(bytes, at: i, with: Array("...".utf8)) {
                tokens.mark(i..<lineEnd, .keyword)
            } else {
                while i < lineEnd, bytes[i] == UInt8(ascii: "-"), i + 1 == lineEnd || bytes[i + 1] == UInt8(ascii: " ") {
                    i += 2
                }
                // 键：到 `: ` 或行尾的 `:` 为止。
                var j = i
                while j < lineEnd, bytes[j] != UInt8(ascii: ":"), bytes[j] != UInt8(ascii: "#") { j += 1 }
                if j < lineEnd, bytes[j] == UInt8(ascii: ":"), j + 1 == lineEnd || bytes[j + 1] == UInt8(ascii: " "), j > i {
                    tokens.mark(i..<j, .property)
                    i = j + 1
                }
                yamlValue(&tokens, from: i, to: lineEnd)
            }
            lineStart = lineEnd + 1
        }
    }

    private static func yamlValue(_ tokens: inout Tokens, from start: Int, to end: Int) {
        let bytes = tokens.bytes
        var i = start
        while i < end, isSpace(bytes[i]) { i += 1 }
        guard i < end else { return }
        let c = bytes[i]
        if c == UInt8(ascii: "#") {
            tokens.mark(i..<end, .comment)
            return
        }
        if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
            let close = bytes[(i + 1)..<end].firstIndex(of: c) ?? end - 1
            tokens.mark(i..<(close + 1), .string)
            yamlComment(&tokens, from: close + 1, to: end)
            return
        }
        if c == UInt8(ascii: "&") || c == UInt8(ascii: "*") {
            var j = i + 1
            while j < end, !isSpace(bytes[j]) { j += 1 }
            tokens.mark(i..<j, .attribute)
            yamlValue(&tokens, from: j, to: end)
            return
        }
        // 到注释（空格加 #）为止的一个标量。
        var valueEnd = i
        while valueEnd < end, !(bytes[valueEnd] == UInt8(ascii: "#") && isSpace(bytes[valueEnd - 1])) { valueEnd += 1 }
        var trimmedEnd = valueEnd
        while trimmedEnd > i, isSpace(bytes[trimmedEnd - 1]) { trimmedEnd -= 1 }
        let word = String(decoding: bytes[i..<trimmedEnd], as: UTF8.self)
        if yamlKeywords.contains(word.lowercased()) || word == "|" || word == ">" || word == "|-" || word == ">-" {
            tokens.mark(i..<trimmedEnd, .keyword)
        } else if Double(word.replacingOccurrences(of: "_", with: "")) != nil {
            tokens.mark(i..<trimmedEnd, .number)
        }
        yamlComment(&tokens, from: valueEnd, to: end)
    }

    private static func yamlComment(_ tokens: inout Tokens, from start: Int, to end: Int) {
        guard let hash = tokens.bytes[start..<end].firstIndex(of: UInt8(ascii: "#")) else { return }
        tokens.mark(hash..<end, .comment)
    }
}

private extension UInt8 {
    var isASCIIHexDigit: Bool {
        (48...57).contains(self) || (97...102).contains(self) || (65...70).contains(self)
    }
}
