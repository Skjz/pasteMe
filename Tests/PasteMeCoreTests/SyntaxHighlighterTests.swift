import Foundation
import Testing
@testable import PasteMeCore

/// 代码着色（#28）和卡片上显示的部分。
@Suite struct SyntaxHighlighterTests {
    typealias Kind = SyntaxHighlighter.Kind

    /// 着了色的片段，例如 `["func": .keyword, …]`，按出现顺序。
    private func colored(_ text: String, _ language: CodeLanguage) -> [String] {
        SyntaxHighlighter.segments(of: text, language: language).compactMap { segment in
            segment.kind.map { "\(segment.text.trimmingCharacters(in: .whitespaces))=\($0)" }
        }
    }

    @Test func segmentsCoverTheWholeText() {
        for language in CodeLanguage.allCases {
            let text = "let x = \"a\" // c\n<a b=\"c\">d</a>\nkey: 1 # e\n{ \"k\": [1, true] }\n.a { color: #fff; }"
            #expect(SyntaxHighlighter.segments(of: text, language: language).map(\.text).joined() == text, "\(language)")
        }
    }

    @Test func swift() {
        #expect(colored(#"@State private var count = 0 // 计数"#, .swift)
            == ["@State=attribute", "private=keyword", "var=keyword", "0=number", "// 计数=comment"])
        #expect(colored(#"guard let url = URL(string: "https://a.b/\(id)") else { return }"#, .swift)
            == ["guard=keyword", "let=keyword", "URL=type", "\"https://a.b/\\(id)\"=string", "else=keyword", "return=keyword"])
        #expect(colored("func load() async throws -> [User] {", .swift)
            == ["func=keyword", "load=function", "async=keyword", "throws=keyword", "User=type"])
        #expect(colored("let s = \"\"\"\n  hi \"quoted\"\n  \"\"\"", .swift)
            == ["let=keyword", "\"\"\"\n  hi \"quoted\"\n  \"\"\"=string"])
    }

    @Test func cFamilyPreprocessorAndTypes() {
        #expect(colored("#include <stdio.h>\nint main(void) { printf(\"%d\\n\", 42); }", .c)
            == ["#include=keyword", "<stdio.h>=string", "int=type", "main=function", "void=type", "printf=function", "\"%d\\n\"=string", "42=number"])
        #expect(colored("@interface Person : NSObject\n@property NSString *name;\n@end", .objectiveC)
            == ["@interface=keyword", "Person=type", "NSObject=type", "@property=keyword", "NSString=type", "@end=keyword"])
        #expect(colored("std::vector<int> v = {0x1F, 2};", .cpp) == ["int=type", "0x1F=number", "2=number"])
    }

    @Test func rustLifetimesMacrosAndChars() {
        #expect(colored("fn first<'a>(s: &'a str) -> char { println!(\"{}\", 'x'); }", .rust)
            == ["fn=keyword", "'a=attribute", "'a=attribute", "str=type", "char=type", "println!=function", "\"{}\"=string", "'x'=string"])
    }

    @Test func javaScriptAndTypeScript() {
        #expect(colored("const msg = `hi ${name}`; console.log(msg);", .javascript)
            == ["const=keyword", "`hi ${name}`=string", "log=function"])
        #expect(colored("interface User { id: number; name?: string }", .typescript)
            == ["interface=keyword", "User=type", "number=type", "string=type"])
    }

    @Test func pythonCommentsDecoratorsAndTripleQuotes() {
        #expect(colored("@dataclass\nclass Point:\n    \"\"\"A point.\"\"\"\n    x: int = 0  # 横坐标", .python)
            == ["@dataclass=attribute", "class=keyword", "Point=type", "\"\"\"A point.\"\"\"=string", "int=type", "0=number", "# 横坐标=comment"])
    }

    @Test func shellVariablesAndComments() {
        #expect(colored("for f in *.png; do echo \"$f\" ${#f} $HOME # done\ndone", .shell)
            == ["for=keyword", "in=keyword", "do=keyword", "\"$f\"=string", "${#f}=variable", "$HOME=variable", "# done=comment", "done=keyword"])
    }

    @Test func rubyInstanceVariablesAndPhpVariables() {
        #expect(colored("def greet\n  puts \"Hi #{@name}\"\n  @count += 1\nend", .ruby)
            == ["def=keyword", "greet", "\"Hi #{@name}\"=string", "@count=variable", "1=number", "end=keyword"].filter { $0.contains("=") })
        #expect(colored("$user = User::find($id); // 查找", .php)
            == ["$user=variable", "User=type", "find=function", "$id=variable", "// 查找=comment"])
    }

    @Test func sqlKeywordsInAnyCase() {
        #expect(colored("select id, name from users where id = 1 -- 一个", .sql)
            == ["select=keyword", "from=keyword", "where=keyword", "1=number", "-- 一个=comment"])
        #expect(colored("CREATE TABLE t (id INTEGER PRIMARY KEY, s TEXT DEFAULT 'x');", .sql)
            == ["CREATE=keyword", "TABLE=keyword", "INTEGER=type", "PRIMARY=keyword", "KEY=keyword", "TEXT=type", "DEFAULT=keyword", "'x'=string"])
    }

    @Test func markup() {
        #expect(colored("<!-- c --><div class=\"a\" hidden>hi</div>", .html)
            == ["<!-- c -->=comment", "div=tag", "class=property", "\"a\"=string", "hidden=property", "div=tag"])
        #expect(colored("<?xml version=\"1.0\"?>\n<key>Name</key>", .xml)
            == ["<?xml version=\"1.0\"?>=keyword", "key=tag", "key=tag"])
    }

    @Test func css() {
        #expect(colored(".button:hover { color: #fff; margin: 0 4px; font: 12px \"SF Pro\" !important; }", .css)
            == [".button:hover=type", "color=property", "#fff=number", "margin=property", "0=number", "4px=number",
                "font=property", "12px=number", "\"SF Pro\"=string", "!important=keyword"])
        #expect(colored("@media (max-width: 600px) {\n  a { color: rgb(0 0 0); }\n}", .css)
            == ["@media=keyword", "max-width=property", "600px=number", "a=tag", "color=property", "rgb=function", "0=number", "0=number", "0=number"])
    }

    @Test func jsonAndYAML() {
        #expect(colored(#"{"name": "PasteMe", "n": -1.5, "ok": true, "x": null}"#, .json)
            == ["\"name\"=property", "\"PasteMe\"=string", "\"n\"=property", "-1.5=number", "\"ok\"=property", "true=keyword", "\"x\"=property", "null=keyword"])
        #expect(colored("---\nname: CI # 名字\non:\n  - push\nretries: 3\nbase: &b\nfast: true", .yaml)
            == ["---=keyword", "name=property", "# 名字=comment", "on=property", "retries=property", "3=number", "base=property", "&b=attribute", "fast=property", "true=keyword"])
    }

    @Test func displayTextDedentsExpandsTabsAndStopsAfterMaxLines() {
        let text = "\n\n\t\tif x {\n\t\t\ty()  \n\t\t}\n\t\tz()\n"
        #expect(CodeSnippet.displayText(text, maxLines: 3) == "if x {\n    y()\n}")
        #expect(CodeSnippet.displayText("a\r\nb", maxLines: 5) == "a\nb")
    }

    @Test func longLinesAreCutWithAnEllipsisInsteadOfWrapping() {
        let segments = SyntaxHighlighter.segments(of: "let message = \"hello world\"\nok", language: .swift)
        let cut = CodeSnippet.truncating(segments, maxColumns: 16)
        #expect(cut.map(\.text).joined() == "let message = \"…\nok")
        #expect(cut.first == SyntaxHighlighter.Segment("let", .keyword))
        // 中文算两列。
        let chinese = CodeSnippet.truncating([SyntaxHighlighter.Segment("// 这是一行很长的注释", .comment)], maxColumns: 10)
        #expect(chinese.map(\.text).joined() == "// 这是一…")
        let short = [SyntaxHighlighter.Segment("ok", nil)]
        #expect(CodeSnippet.truncating(short, maxColumns: 10) == short)
    }
}
