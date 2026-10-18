import Foundation

/// 识别一段文本是哪种编程语言的代码（#28）。拿不准时为 nil：宁可漏掉，也不把普通文字、聊天记录、Markdown 当成代码。
///
/// 只看前 `sampleLength` 个字符，逐行比较，不用正则（记录时在主线程上算，补算旧条目时一次算一批）：
///
/// 1. 确定的标记：shebang、`<?php`、`<?xml`、`<!DOCTYPE html>`、能解析的 JSON。
/// 2. 排除散文和 Markdown：有 ``` 围栏，或者三成以上的行像句子（词多、没有代码符号、句号结尾，或者主要是中文）。
/// 3. 标记语言：HTML/XML 看标签，YAML 要每行都是 `键: 值` 或 `- 项`、而且有嵌套或列表。
/// 4. 其余的按行打分：每种语言有一组只在它（或它那一族）里出现的写法（`Signal`），每种写法最多算 3 行。
///    最高分要过门槛、并且比第二名至少多 2 分。C 和 C++、Objective-C，JavaScript 和 TypeScript 各算一族，
///    族里先比通用的写法，再看有没有 C++ / Objective-C / TypeScript 独有的写法。
///
/// 从编辑器复制的内容门槛低一些；从终端复制的，行首是常用命令时算作 Shell 的证据更足。
enum CodeDetector {
    static let sampleLength = 4000
    /// 最多看这么多个非空行。
    static let lineLimit = 80

    static func language(of text: String, sourceBundleID: String?) -> CodeLanguage? {
        let source = SourceKind(bundleID: sourceBundleID)
        let trimmed = text.prefix(sampleLength).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count >= 3 else { return nil }
        if let marked = markedLanguage(trimmed, fullText: text) { return marked }

        let lines = Self.lines(of: trimmed)
        guard !lines.isEmpty, !looksLikeProse(lines) else { return nil }
        if let markup = markupLanguage(trimmed) { return markup }
        if isYAML(lines) { return .yaml }

        return decide(scores(of: lines, source: source), threshold: source.threshold)
    }

    /// 各语言的原始得分（C++、Objective-C、TypeScript 只含独有的写法）。注释里写的东西不算。
    static func scores(of allLines: [Line], source: SourceKind) -> [CodeLanguage: Int] {
        let lines = allLines.filter { !$0.isComment }
        var scores: [CodeLanguage: Int] = [:]
        for (language, signals) in Self.signals {
            scores[language] = score(lines, signals)
        }
        scores[.css] = cssScore(lines)
        scores[.sql] = sqlScore(lines)
        scores[.shell, default: 0] += shellCommandScore(lines, source: source)
        return scores
    }

    // MARK: - 来源应用

    enum SourceKind {
        case editor
        case terminal
        case other

        init(bundleID: String?) {
            guard let id = bundleID?.lowercased() else {
                self = .other
                return
            }
            if Self.terminals.contains(id) {
                self = .terminal
            } else if Self.editors.contains(id) || Self.editorPrefixes.contains(where: id.hasPrefix) {
                self = .editor
            } else {
                self = .other
            }
        }

        /// 最高分至少要这么多。
        var threshold: Int {
            switch self {
            case .editor: 3
            case .terminal: 4
            case .other: 6
            }
        }

        static let editors: Set<String> = [
            "com.apple.dt.xcode", "com.microsoft.vscode", "com.microsoft.vscodeinsiders", "com.vscodium",
            "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.zed", "com.google.android.studio",
            "com.sublimetext.4", "com.sublimetext.3", "com.panic.nova", "com.barebones.bbedit", "com.macromates.textmate",
            "org.vim.macvim", "org.gnu.emacs", "com.coteditor.coteditor", "com.apple.dt.swiftplaygrounds",
        ]
        static let editorPrefixes = ["com.jetbrains."]
        static let terminals: Set<String> = [
            "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "net.kovidgoyal.kitty",
            "org.alacritty", "io.alacritty", "com.mitchellh.ghostty", "co.zeit.hyper", "com.github.wez.wezterm",
        ]
    }

    // MARK: - 行

    struct Line {
        /// 去掉首尾空白后的 UTF-8。
        let bytes: [UInt8]
        /// 行首空白的宽度，tab 算 4。
        let indent: Int

        func hasPrefix(_ p: [UInt8]) -> Bool {
            bytes.count >= p.count && bytes.withUnsafeBytes { b in p.withUnsafeBytes { memcmp(b.baseAddress!, $0.baseAddress!, p.count) == 0 } }
        }

        func hasSuffix(_ p: [UInt8]) -> Bool {
            bytes.count >= p.count && bytes.withUnsafeBytes { b in
                p.withUnsafeBytes { memcmp(b.baseAddress! + (bytes.count - p.count), $0.baseAddress!, p.count) == 0 }
            }
        }

        func contains(_ p: [UInt8]) -> Bool {
            bytes.count >= p.count && bytes.withUnsafeBytes { b in
                p.withUnsafeBytes { memmem(b.baseAddress!, bytes.count, $0.baseAddress!, p.count) != nil }
            }
        }

        func equals(_ p: [UInt8]) -> Bool { bytes == p }

        /// 注释行：`//`、`/*`、块注释中间的 `* `、`# `（`#include`、`#[derive`、`#!` 不算）、`-- `、`<!--`。
        var isComment: Bool {
            guard let first = bytes.first else { return false }
            switch first {
            case UInt8(ascii: "/"): return hasPrefix(Self.slashes) || hasPrefix(Self.blockOpen)
            case UInt8(ascii: "*"): return bytes.count == 1 || bytes[1] == UInt8(ascii: " ") || bytes[1] == UInt8(ascii: "/")
            case UInt8(ascii: "#"): return bytes.count == 1 || bytes[1] == UInt8(ascii: " ") || bytes[1] == UInt8(ascii: "#")
            case UInt8(ascii: "-"): return hasPrefix(Self.dashes)
            case UInt8(ascii: "<"): return hasPrefix(Self.htmlComment)
            default: return false
            }
        }

        private static let slashes = Array("//".utf8)
        private static let blockOpen = Array("/*".utf8)
        private static let dashes = Array("-- ".utf8)
        private static let htmlComment = Array("<!--".utf8)
    }

    static func lines(of text: String) -> [Line] {
        var result: [Line] = []
        for raw in text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            var indent = 0
            var start = raw.startIndex
            while start < raw.endIndex, raw[start] == UInt8(ascii: " ") || raw[start] == UInt8(ascii: "\t") {
                indent += raw[start] == UInt8(ascii: "\t") ? 4 : 1
                start = raw.index(after: start)
            }
            var bytes = Array(raw[start...])
            while let last = bytes.last, last == UInt8(ascii: " ") || last == UInt8(ascii: "\t") || last == UInt8(ascii: "\r") {
                bytes.removeLast()
            }
            guard !bytes.isEmpty else { continue }
            result.append(Line(bytes: bytes, indent: indent))
            if result.count == lineLimit { break }
        }
        return result
    }

    // MARK: - 确定的标记

    private static func markedLanguage(_ trimmed: String, fullText: String) -> CodeLanguage? {
        if trimmed.hasPrefix("#!") {
            let firstLine = trimmed.prefix { !$0.isNewline }
            for (word, language) in [
                ("python", CodeLanguage.python), ("ts-node", .typescript), ("node", .javascript), ("deno", .typescript),
                ("ruby", .ruby), ("php", .php), ("swift", .swift),
                ("bash", .shell), ("zsh", .shell), ("/sh", .shell), (" sh", .shell), ("fish", .shell), ("dash", .shell),
            ] where firstLine.contains(word) {
                return language
            }
        }
        if trimmed.hasPrefix("<?php") { return .php }
        if trimmed.hasPrefix("<?xml") { return .xml }
        let head = trimmed.prefix(15).lowercased()
        if head.hasPrefix("<!doctype html") || head.hasPrefix("<html") { return .html }
        if let first = trimmed.first, let last = trimmed.last,
           (first == "{" && last == "}") || (first == "[" && last == "]"),
           trimmed.contains("\""),
           fullText.utf8.count <= TextSubtype.maxLength,
           (try? JSONSerialization.jsonObject(with: Data(fullText.utf8))) != nil {
            return .json
        }
        return nil
    }

    // MARK: - 散文和 Markdown

    /// 有 Markdown 的代码围栏或表格，或者三成以上的行（不算注释）像句子。
    static func looksLikeProse(_ lines: [Line]) -> Bool {
        if lines.contains(where: { $0.hasPrefix(fence) }) { return true }
        if lines.filter({ $0.hasPrefix(bar) && $0.hasSuffix(bar) }).count >= 2 { return true }
        var counted = 0
        var prose = 0
        for line in lines where !line.isComment {
            counted += 1
            if isSentence(line) { prose += 1 }
        }
        return counted > 0 && prose * 10 >= counted * 3
    }

    private static let fence = Array("```".utf8)
    private static let bar = Array("|".utf8)
    private static let codeSymbols = Set("{}();=<>[]$".utf8)
    private static let sentenceEnds: [[UInt8]] = [".", "。", "!", "?", "！", "？", "，", "：", "…", "；"].map { Array($0.utf8) }
    private static let commaSpace = Array(", ".utf8)

    /// 像一句话：中文、日文、韩文为主而且没有 `;`、`{`，或者至少 6 个词、代码符号很少（每 8 个词不到一个），
    /// 并且以标点结尾或者中间有逗号。
    private static func isSentence(_ line: Line) -> Bool {
        var cjk = 0
        var characters = 0
        var words = 0
        var symbols = 0
        var inWord = false
        var wordHasLetter = false
        for byte in line.bytes {
            if byte == UInt8(ascii: " ") {
                if inWord, wordHasLetter { words += 1 }
                inWord = false
                wordHasLetter = false
                continue
            }
            inWord = true
            if (0x80...0xBF).contains(byte) { continue }  // UTF-8 的后续字节
            characters += 1
            if (0xE3...0xED).contains(byte) { cjk += 1 }  // 中日韩文字的首字节
            if byte >= 0x80 || (65...90).contains(byte) || (97...122).contains(byte) { wordHasLetter = true }
            if codeSymbols.contains(byte) { symbols += 1 }
        }
        if inWord, wordHasLetter { words += 1 }
        if cjk >= 4, cjk * 10 >= characters * 4, !line.bytes.contains(UInt8(ascii: ";")), !line.bytes.contains(UInt8(ascii: "{")) {
            return true
        }
        guard words >= 6, symbols * 8 < words else { return false }
        return sentenceEnds.contains(where: line.hasSuffix) || line.contains(commaSpace)
    }

    // MARK: - HTML、XML、YAML

    private static let htmlTags: Set<String> = [
        "html", "head", "body", "div", "span", "p", "a", "ul", "ol", "li", "table", "tr", "td", "th", "img", "br",
        "script", "style", "meta", "link", "form", "input", "button", "h1", "h2", "h3", "h4", "h5", "h6",
        "section", "nav", "header", "footer", "main", "article", "label", "select", "option", "textarea", "iframe",
        "strong", "em", "b", "i", "code", "pre", "template", "svg",
    ]

    /// 以 `<` 开头、`>` 结尾，有结束标签或自闭合标签。有常见的 HTML 标签时是 HTML，否则是 XML。
    private static func markupLanguage(_ trimmed: String) -> CodeLanguage? {
        guard trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), trimmed.contains("</") || trimmed.contains("/>") else {
            return nil
        }
        var names: [String] = []
        var rest = Substring(trimmed)
        while let open = rest.firstIndex(of: "<") {
            rest = rest[rest.index(after: open)...]
            if rest.first == "/" { rest = rest.dropFirst() }
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == ":" }
            if !name.isEmpty { names.append(name.lowercased()) }
        }
        guard names.count >= 2, let firstChar = trimmed.dropFirst().first, firstChar.isLetter || firstChar == "!" else {
            return nil
        }
        return names.contains(where: htmlTags.contains) ? .html : .xml
    }

    /// 每行（不算注释）都是 `键: 值`、`键:`、`- 项`、`---`，或者块标量（`|`、`>`）下面缩进的内容；
    /// 至少两个键，并且有 `---` 开头、列表或者嵌套。邮件头（`From: …`）没有嵌套，不算。
    static func isYAML(_ lines: [Line]) -> Bool {
        let content = lines.filter { !$0.hasPrefix(Array("#".utf8)) }
        guard content.count >= 2 else { return false }
        var keys = 0
        var structured = content.first?.equals(Array("---".utf8)) ?? false
        var blockIndent: Int?
        var previousKeyIndent: Int?
        for line in content {
            if let indent = blockIndent, line.indent > indent { continue }
            blockIndent = nil
            if line.equals(Array("---".utf8)) || line.equals(Array("...".utf8)) { continue }
            if line.hasSuffix(Array(";".utf8)) || line.hasSuffix(Array("{".utf8)) { return false }
            var body = line.bytes[...]
            if line.hasPrefix(Array("- ".utf8)) || line.equals(Array("-".utf8)) {
                structured = true
                body = body.dropFirst(2)
                if body.isEmpty || keyLength(body) == nil { continue }
            }
            guard let keyEnd = keyLength(body) else { return false }
            keys += 1
            let value = body[(body.startIndex + keyEnd + 1)...].drop { $0 == UInt8(ascii: " ") }
            if let previous = previousKeyIndent, line.indent > previous { structured = true }
            previousKeyIndent = value.isEmpty ? line.indent : nil
            if value.elementsEqual("|".utf8) || value.elementsEqual(">".utf8)
                || value.elementsEqual("|-".utf8) || value.elementsEqual(">-".utf8) {
                blockIndent = line.indent
            }
        }
        return keys >= 2 && structured
    }

    /// `key:` 或 `key: …` 里键的长度（冒号的位置）。键是字母、数字、`_`、`-`、`.` 组成的，或者带引号。
    private static func keyLength(_ body: ArraySlice<UInt8>) -> Int? {
        guard let first = body.first else { return nil }
        var index = body.startIndex
        if first == UInt8(ascii: "\"") || first == UInt8(ascii: "'") {
            guard let close = body.dropFirst().firstIndex(of: first) else { return nil }
            index = close + 1
        } else {
            guard (65...90).contains(first) || (97...122).contains(first) || first == UInt8(ascii: "_") else { return nil }
            while index < body.endIndex {
                let c = body[index]
                guard (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c)
                    || c == UInt8(ascii: "_") || c == UInt8(ascii: "-") || c == UInt8(ascii: ".")
                else { break }
                index += 1
            }
        }
        guard index < body.endIndex, body[index] == UInt8(ascii: ":") else { return nil }
        let next = index + 1
        guard next == body.endIndex || body[next] == UInt8(ascii: " ") else { return nil }
        return index - body.startIndex
    }

    // MARK: - 打分

    /// 一种写法。`weight` 是每出现一行加的分，最多算 3 行。
    struct Signal: Sendable {
        enum Test: Sendable {
            case prefix([UInt8])
            case contains([UInt8])
            case suffix([UInt8])
            case line([UInt8])
            case prefixSuffix([UInt8], [UInt8])
            case prefixContains([UInt8], [UInt8])
            /// 行首是这个，行尾不是那个（Python 的 `def …:` 和 Ruby 的 `def …`）。
            case prefixNotSuffix([UInt8], [UInt8])
        }

        let test: Test
        let weight: Int

        func matches(_ line: Line) -> Bool {
            switch test {
            case .prefix(let p): line.hasPrefix(p)
            case .contains(let p): line.contains(p)
            case .suffix(let p): line.hasSuffix(p)
            case .line(let p): line.equals(p)
            case .prefixSuffix(let p, let s): line.hasPrefix(p) && line.hasSuffix(s)
            case .prefixContains(let p, let c): line.hasPrefix(p) && line.contains(c)
            case .prefixNotSuffix(let p, let s): line.hasPrefix(p) && !line.hasSuffix(s)
            }
        }

        static func p(_ s: String, _ w: Int) -> Signal { Signal(test: .prefix(Array(s.utf8)), weight: w) }
        static func c(_ s: String, _ w: Int) -> Signal { Signal(test: .contains(Array(s.utf8)), weight: w) }
        static func s(_ s: String, _ w: Int) -> Signal { Signal(test: .suffix(Array(s.utf8)), weight: w) }
        static func l(_ s: String, _ w: Int) -> Signal { Signal(test: .line(Array(s.utf8)), weight: w) }
        static func ps(_ p: String, _ s: String, _ w: Int) -> Signal {
            Signal(test: .prefixSuffix(Array(p.utf8), Array(s.utf8)), weight: w)
        }
        static func pc(_ p: String, _ c: String, _ w: Int) -> Signal {
            Signal(test: .prefixContains(Array(p.utf8), Array(c.utf8)), weight: w)
        }
        static func pn(_ p: String, _ s: String, _ w: Int) -> Signal {
            Signal(test: .prefixNotSuffix(Array(p.utf8), Array(s.utf8)), weight: w)
        }
    }

    private static func score(_ lines: [Line], _ signals: [Signal]) -> Int {
        var total = 0
        for signal in signals {
            var hits = 0
            for line in lines where signal.matches(line) {
                hits += 1
                if hits == 3 { break }
            }
            total += hits * signal.weight
        }
        return total
    }

    private static func decide(_ raw: [CodeLanguage: Int], threshold: Int) -> CodeLanguage? {
        var scores = raw
        // C 一族：C++、Objective-C 独有的写法够多时才是它们。
        let cBase = raw[.c] ?? 0
        let cpp = raw[.cpp] ?? 0
        let objc = raw[.objectiveC] ?? 0
        scores[.cpp] = nil
        scores[.objectiveC] = nil
        if objc >= 3, objc >= cpp {
            scores[.c] = nil
            scores[.objectiveC] = cBase + objc
        } else if cpp >= 3 {
            scores[.c] = nil
            scores[.cpp] = cBase + cpp
        }
        // JavaScript 一族。
        let ts = raw[.typescript] ?? 0
        scores[.typescript] = nil
        if ts >= 3 {
            scores[.typescript] = (raw[.javascript] ?? 0) + ts
            scores[.javascript] = nil
        }

        let ranked = scores.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= threshold else { return nil }
        let second = ranked.dropFirst().first?.value ?? 0
        return best.value - second >= 2 ? best.key : nil
    }

    // MARK: - CSS、SQL、Shell 的特别规则

    /// 声明行（`color: red;`）和选择器行（`.a {`），以及写在一行里的规则（`.a { color: red; }`）。
    static func cssScore(_ lines: [Line]) -> Int {
        var declarations = 0
        var selectors = 0
        for line in lines {
            let text = String(decoding: line.bytes, as: UTF8.self)
            if let open = text.firstIndex(of: "{") {
                let selector = text[..<open].trimmingCharacters(in: .whitespaces)
                if isSelector(selector) { selectors += 1 }
                let body = text[text.index(after: open)...]
                declarations += body.split(separator: ";").filter { isDeclaration($0) }.count
            } else if isDeclaration(text[...]), text.hasSuffix(";") {
                declarations += 1
            }
        }
        guard selectors > 0, declarations > 0 else { return 0 }
        return min(selectors, 3) * 2 + min(declarations, 4) * 2
    }

    private static func isSelector(_ text: String) -> Bool {
        guard let first = text.first, !text.contains("="), !text.contains(";"), !text.contains("("),
              first == "." || first == "#" || first == "@" || first == ":" || first == "*" || first == "["
                || (first.isLetter && first.isLowercase)
        else {
            return text.hasPrefix("@media") || text.hasPrefix(":root")
        }
        // `if x {`、`func f {` 这样的代码不是选择器。
        let firstWord = text.prefix { $0.isLetter }
        return !["if", "for", "while", "func", "fn", "function", "class", "struct", "else", "do", "try", "switch",
                 "enum", "impl", "interface", "object", "return", "match", "loop", "type", "fun", "def", "catch"]
            .contains(String(firstWord))
    }

    /// `prop: value`，属性名是小写字母和 `-`。
    private static func isDeclaration(_ part: Substring) -> Bool {
        let trimmed = part.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "}"))
            .trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(of: ":") else { return false }
        let name = trimmed[..<colon]
        let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && name.allSatisfy { $0 == "-" || ($0.isLetter && $0.isLowercase) }
            && !value.isEmpty && !value.contains("=") && !value.hasSuffix(",")
    }

    private static let sqlSignals: [Signal] = [
        .p("SELECT ", 4), .p("INSERT INTO ", 6), .pc("UPDATE ", " SET ", 6), .p("DELETE FROM ", 6),
        .p("CREATE TABLE", 6), .p("CREATE INDEX", 6), .p("CREATE VIEW", 6), .p("ALTER TABLE", 6), .p("DROP TABLE", 6),
        .pc("WITH ", " AS (", 5), .c("FROM ", 2), .c("WHERE ", 3), .c(" JOIN ", 3), .c("GROUP BY", 4),
        .c("ORDER BY", 4), .c("VALUES", 2), .c("PRIMARY KEY", 4), .c("NOT NULL", 3),
    ]
    private static let lowercaseSQLSignals: [Signal] = [
        .p("select ", 2), .p("insert into ", 4), .p("delete from ", 4), .pc("update ", " set ", 4),
        .p("create table", 5), .c(" from ", 2), .c("where ", 2), .c(" join ", 2), .c("group by", 3), .c("order by", 3),
    ]

    private static let lowercaseStatements: [[UInt8]] = ["select ", "insert into ", "update ", "delete from ", "create table", "with "]
        .map { Array($0.utf8) }

    /// 关键字大写的 SQL。小写的要有一行以语句开头（`select …`），并且只看有 `*`、`=`、`;`、`(`、`,` 的行，
    /// 免得「Select the file from the menu」这样的句子被当成 SQL。
    static func sqlScore(_ lines: [Line]) -> Int {
        let uppercase = score(lines, sqlSignals)
        let sqlPunctuation = Set("*=;(,".utf8)
        let lower = lines.filter { $0.bytes.contains(where: sqlPunctuation.contains) }.map { line in
            Line(bytes: line.bytes.map { (65...90).contains($0) ? $0 + 32 : $0 }, indent: line.indent)
        }
        guard lower.contains(where: { line in lowercaseStatements.contains(where: line.hasPrefix) }) else { return uppercase }
        return max(uppercase, score(lower, lowercaseSQLSignals))
    }

    private static let shellCommands: Set<String> = [
        "cd", "ls", "git", "brew", "npm", "npx", "yarn", "pnpm", "sudo", "echo", "curl", "wget", "grep", "cat", "mkdir",
        "rm", "cp", "mv", "chmod", "chown", "ssh", "scp", "rsync", "docker", "kubectl", "pip", "pip3", "python",
        "python3", "swift", "xcodebuild", "xcrun", "make", "cmake", "open", "defaults", "launchctl", "source", "tar",
        "unzip", "zip", "find", "xargs", "sed", "awk", "head", "tail", "sort", "uniq", "wc", "ps", "kill", "pkill",
        "pgrep", "touch", "ln", "du", "df", "go", "cargo", "node", "deno", "bun", "gh", "export", "which", "man",
        "diff", "tee", "jq", "ffmpeg", "sqlite3", "codesign", "plutil", "mdfind", "killall", "lsof", "ping", "dig",
        "nslookup", "env", "printf", "hexdump", "xxd", "base64", "openssl", "pod", "fastlane", "terraform", "helm",
        "systemctl", "apt", "apt-get", "yum", "dnf", "pacman", "uv", "poetry", "ruby", "gem", "bundle", "rails",
        "php", "composer", "java", "javac", "gradle", "mvn", "rustc", "rustup", "clang", "gcc", "swiftc", "tsc",
    ]

    private static let promptPrefixes: [[UInt8]] = ["$ ", "% ", "❯ ", "➜ "].map { Array($0.utf8) }

    /// 行首（去掉 `$ ` 这样的提示符）是常用命令：每行 2 分，带选项（` -x`、` --x`）再加 1，有管道再加 2；
    /// 从终端复制的再加 2。
    static func shellCommandScore(_ lines: [Line], source: SourceKind) -> Int {
        var total = 0
        var counted = 0
        for line in lines where counted < 3 {
            var bytes = line.bytes[...]
            for prompt in promptPrefixes where bytes.starts(with: prompt) {
                bytes = bytes.dropFirst(prompt.count)
                total += 1
            }
            let word = String(decoding: bytes.prefix { $0 != UInt8(ascii: " ") }, as: UTF8.self)
            guard shellCommands.contains(word) else { continue }
            counted += 1
            total += 2
            let rest = Line(bytes: Array(bytes.dropFirst(word.utf8.count)), indent: 0)
            if rest.contains(Array(" -".utf8)) { total += 1 }
            // 管道只在命令后面才算：`cmdKey | shiftKey` 这样的位运算到处都有。
            if rest.contains(Array(" | ".utf8)) { total += 2 }
            if source == .terminal { total += 2 }
        }
        return total
    }
}
