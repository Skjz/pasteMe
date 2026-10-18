import Foundation

/// 各语言的写法和分数（见 `CodeDetector`）。每种写法每出现一行加一次分，最多算 3 行。
///
/// 只放能区分语言的写法：`if (`、`return`、行尾的 `;` 这些很多语言都有，不放进来。几种语言共有的写法
/// （Swift 和 Go 的 `func `）给每种语言都加，再靠其他写法分出高下。分数大致是：
/// 6 一行就能确定（`console.log(`、`package main`），4–5 很有特点，2–3 有倾向，1 只是佐证。
/// C++ 和 Objective-C 只列独有的写法（加在 C 的分上），TypeScript 也只列独有的（加在 JavaScript 上）。
extension CodeDetector {
    typealias S = Signal

    static let signals: [CodeLanguage: [Signal]] = [
        .swift: [
            S.p("import Foundation", 5), S.p("import SwiftUI", 6), S.p("import UIKit", 6), S.p("import AppKit", 6),
            S.p("import Combine", 4), S.p("import XCTest", 6), S.p("import Testing", 4),
            S.p("guard let ", 5), S.pc("guard ", " else {", 4), S.p("if let ", 4), S.p("if var ", 4),
            S.p("func ", 2), S.p("private func ", 3), S.p("fileprivate ", 5), S.p("static func ", 3),
            S.p("override func ", 5), S.p("mutating func ", 6), S.p("@objc ", 4), S.p("@discardableResult", 6),
            S.c(") -> ", 2), S.c(") throws -> ", 5), S.c(" async throws", 4), S.c("try await ", 3),
            S.p("@State ", 6), S.p("@Published ", 6), S.p("@Binding ", 6), S.p("@MainActor", 4),
            S.p("@Observable", 5), S.p("@Environment(", 6), S.p("@main", 3), S.c("@escaping", 5),
            S.c("some View", 6), S.c(": View {", 5), S.p("var body: ", 4),
            S.p("extension ", 3), S.p("protocol ", 3), S.p("case .", 4), S.c("\\(", 2),
            S.c(": [String", 3), S.c("?? ", 1), S.p("defer {", 4), S.p("deinit", 4), S.p("init(", 3),
            S.s(" in", 1), S.p("print(", 1), S.c("Self.", 2), S.p("let ", 1), S.c("#selector(", 5),
            S.c("[weak self]", 6), S.c(": CGFloat", 4), S.p("static let ", 3), S.p("private let ", 3),
            S.pn("try ", "{", 2), S.pc("let ", " = try ", 3),
        ],
        .objectiveC: [
            S.p("#import ", 6), S.p("@interface ", 6), S.p("@implementation ", 6), S.l("@end", 5),
            S.p("@property ", 4), S.p("@property(", 4), S.p("@synthesize ", 5), S.p("@protocol ", 4),
            S.p("- (", 4), S.p("+ (", 4), S.c("NSString *", 5), S.c("NSArray *", 4), S.c("NSDictionary *", 4),
            S.c("@\"", 3), S.c(" alloc] init", 6), S.c("[self ", 4), S.c("[super ", 4), S.c("NS_ASSUME_NONNULL", 6),
        ],
        .c: [
            S.p("#include <", 4), S.p("#include \"", 4), S.p("#define ", 3), S.p("#ifdef ", 3), S.p("#ifndef ", 3),
            S.l("#endif", 3), S.p("#pragma ", 3), S.c("printf(", 3), S.c("malloc(", 4), S.c("free(", 2),
            S.c("sizeof(", 3), S.c("NULL", 2), S.p("typedef ", 3), S.c("unsigned ", 2), S.c("char *", 3),
            S.p("int main(", 5), S.p("static int ", 3), S.p("static void ", 3), S.p("void ", 1), S.c("uint8_t", 4),
            S.c("size_t", 3), S.c("int32_t", 4), S.c("->", 1),
        ],
        .cpp: [
            S.p("#include <iostream>", 6), S.p("#include <vector>", 6), S.p("#include <string>", 4),
            S.p("#include <memory>", 6), S.p("#include <algorithm>", 6), S.p("#include <map>", 5),
            S.c("std::", 5), S.c("using namespace std", 6), S.c("cout <<", 5), S.c("cin >>", 5),
            S.p("template <", 5), S.p("template<", 5), S.c("nullptr", 4), S.l("public:", 4), S.l("private:", 4),
            S.l("protected:", 4), S.c("const auto&", 4), S.c("virtual ", 4), S.c("unique_ptr<", 5), S.c("shared_ptr<", 5),
            S.c("::", 1),
        ],
        .csharp: [
            S.p("using System", 6), S.p("using Microsoft.", 6), S.c("Console.WriteLine(", 6), S.c("{ get; set; }", 6),
            S.c("{ get; }", 5), S.p("public static void Main(", 6), S.c("async Task", 5), S.c("Task<", 3),
            S.p("public sealed class ", 4), S.p("internal ", 3), S.p("[Serializable]", 4), S.c("List<string>", 4),
            S.c("Dictionary<string", 4), S.c(" is null", 3), S.c(".ToString()", 4), S.c("nameof(", 4), S.p("#region", 5),
            S.p("namespace ", 2), S.c("string ", 1), S.p("public override ", 3),
        ],
        .java: [
            S.p("import java.", 6), S.p("import javax.", 6), S.ps("import android.", ";", 5), S.ps("package ", ";", 4),
            S.c("System.out.println(", 6), S.c("System.out.print", 5), S.c("String[] args", 4), S.p("@Override", 4),
            S.c("private final ", 3), S.c("public final ", 3), S.c("new ArrayList<", 5), S.c("new HashMap<", 5),
            S.c(" throws ", 3), S.c(".equals(", 3), S.p("private static final ", 5), S.c("@Autowired", 6),
            S.p("public void ", 2), S.p("public class ", 1), S.p("public interface ", 2), S.c("String ", 1),
        ],
        .kotlin: [
            S.p("fun ", 4), S.c(" fun ", 4), S.p("val ", 3), S.c(" val ", 2), S.p("data class ", 6),
            S.c("companion object", 6), S.c("?.let {", 5), S.c("listOf(", 5), S.c("mutableListOf(", 6), S.c("mapOf(", 5),
            S.p("lateinit var ", 6), S.p("when (", 3), S.l("when {", 3), S.c(": Unit", 4), S.c("suspend fun", 6),
            S.c("override fun", 5), S.p("object ", 3), S.c("!!", 2), S.p("@Composable", 6), S.c("by lazy", 6),
            S.c("Modifier.", 4), S.c("println(", 1),
        ],
        .go: [
            S.l("package main", 6), S.l("import (", 5), S.p("import \"", 4), S.p("func (", 5), S.p("func ", 2),
            S.c(" := ", 4), S.c("fmt.", 5), S.c("fmt.Print", 2), S.c("fmt.Sprintf(", 2), S.c("err != nil", 6), S.p("if err ", 4), S.c(" chan ", 3), S.p("defer ", 3),
            S.p("go func", 5), S.c("map[string]", 5), S.c("[]string", 4), S.c("[]byte", 4), S.c("interface{}", 5),
            S.ps("type ", " struct {", 5), S.ps("type ", " interface {", 5),
        ],
        .rust: [
            S.p("fn ", 4), S.c(" fn ", 3), S.p("pub fn ", 5), S.p("let mut ", 6), S.c("&mut ", 5), S.p("impl ", 4),
            S.p("impl<", 5), S.p("use std::", 6), S.ps("use ", ";", 1), S.c("println!(", 6), S.c("vec![", 6),
            S.c("format!(", 5), S.p("#[derive(", 6), S.p("#[", 2), S.c("Option<", 2), S.c("Result<", 3),
            S.c(".unwrap()", 5), S.c("::new(", 2), S.p("match ", 2), S.p("pub struct ", 5), S.p("pub enum ", 5),
            S.c("&self", 5), S.c("-> Self", 3), S.c("Some(", 2), S.c("Ok(", 2), S.p("mod ", 3), S.c("&str", 5),
            S.c("String::from(", 6), S.p("pub(crate)", 6),
        ],
        .javascript: [
            S.p("function ", 3), S.c("function(", 3), S.c("=> {", 3), S.c(") => ", 3), S.pc("const ", " = ", 3),
            S.c("console.log(", 6), S.c("console.error(", 6),
            S.c("require(", 3), S.c("module.exports", 6), S.p("export default ", 5), S.p("export const ", 4),
            S.p("export function ", 4), S.pc("import ", " from '", 5), S.pc("import ", " from \"", 5),
            S.c("document.", 2), S.c("window.", 1), S.c("===", 3), S.c("!==", 3), S.c("undefined", 3), S.c(".then(", 3),
            S.c("JSON.stringify(", 4), S.c("JSON.parse(", 4), S.c("addEventListener(", 5), S.c("new Promise(", 5),
            S.c("useState(", 5), S.c("useEffect(", 5),
        ],
        .typescript: [
            S.c(": string", 4), S.c(": number", 4), S.c(": boolean", 4), S.c(": any", 3), S.c(": void", 3),
            S.p("export interface ", 6), S.p("export type ", 6), S.pc("type ", " = ", 4), S.c(" as const", 5),
            S.c("?: ", 3), S.c("private readonly ", 3), S.c(": React.", 5), S.c(": Promise<", 5), S.c("Record<", 4),
            S.p("declare ", 5), S.p("interface ", 2),
        ],
        .python: [
            S.ps("def ", ":", 5), S.ps("async def ", ":", 6), S.ps("class ", ":", 4), S.pc("from ", " import ", 5),
            S.p("elif ", 6), S.ps("if ", ":", 3), S.ps("for ", ":", 3), S.ps("while ", ":", 3), S.l("else:", 4),
            S.l("try:", 5), S.p("except", 5), S.ps("with ", ":", 4), S.c("self.", 1), S.c("__init__", 6),
            S.c("__name__", 6), S.c("None", 2), S.c("lambda ", 3), S.c(" not in ", 3), S.c(" is None", 5),
            S.c(" is not None", 5), S.c("print(f\"", 5), S.p(">>> ", 5), S.c("range(", 3), S.p("raise ", 4),
            S.p("yield ", 3), S.l("pass", 5), S.p("import ", 1), S.c("print(", 1),
        ],
        .ruby: [
            S.pn("def ", ":", 3), S.l("end", 4), S.p("require '", 5), S.p("require \"", 5), S.p("require_relative", 6),
            S.p("puts ", 4), S.c(".each do |", 6), S.c(" do |", 5), S.p("attr_accessor", 6), S.p("attr_reader", 6),
            S.p("module ", 2), S.p("elsif ", 6), S.p("unless ", 4), S.c(".nil?", 6), S.pc("class ", " < ", 4),
            S.s(" do", 4), S.c(".map(&:", 6), S.c("#{", 3), S.p("gem '", 6),
        ],
        .php: [
            S.c("$this->", 6), S.ps("echo ", ";", 3), S.pc("namespace ", "\\", 5), S.pc("use ", "\\", 5),
            S.c("public function ", 4), S.c("private function ", 4), S.c("function __construct", 6), S.c("array(", 3),
            S.c("=> $", 4), S.c("::class", 4), S.c("$_GET", 6), S.c("$_POST", 6), S.ps("$", ";", 2),
        ],
        .shell: [
            S.c(" && ", 1), S.c("$(", 3), S.c("${", 2), S.c(" > /dev/null", 6), S.c("2>&1", 6),
            S.p("if [", 6), S.l("fi", 6), S.l("done", 5), S.l("then", 5), S.c("; then", 6), S.c("; do", 6),
            S.ps("case ", " in", 6), S.l("esac", 6), S.pc("alias ", "=", 4), S.p("export PATH=", 6), S.p("set -e", 5),
            S.p("set -euo", 6), S.p("./", 2),
        ],
    ]
}
