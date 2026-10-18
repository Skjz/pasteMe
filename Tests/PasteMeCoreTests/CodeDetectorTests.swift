import Foundation
import Testing
@testable import PasteMeCore

/// 识别代码的语言（#28）：真实的代码片段要认对，普通文字、Markdown、邮件、聊天记录、数学式都不能当成代码。
@Suite struct CodeDetectorTests {
    private func detect(_ text: String, from bundleID: String? = nil) -> CodeLanguage? {
        CodeDetector.language(of: text, sourceBundleID: bundleID)
    }

    private func expect(_ language: CodeLanguage, _ samples: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        for sample in samples {
            #expect(detect(sample) == language, "\(sample)", sourceLocation: sourceLocation)
            // 存成文本子类型后，标题栏显示语言。
            #expect(TextSubtype.detect(sample) == .code(language), sourceLocation: sourceLocation)
        }
    }

    @Test func swift() {
        expect(.swift, [
            #"""
            import SwiftUI

            struct ContentView: View {
                @State private var count = 0

                var body: some View {
                    Button("Tapped \(count) times") { count += 1 }
                }
            }
            """#,
            #"""
            func loadUser(id: Int) async throws -> User {
                guard let url = URL(string: "https://api.example.com/users/\(id)") else {
                    throw APIError.badURL
                }
                let (data, _) = try await URLSession.shared.data(from: url)
                return try JSONDecoder().decode(User.self, from: data)
            }
            """#,
            #"""
            extension Array where Element: Equatable {
                mutating func removeFirst(_ element: Element) {
                    if let index = firstIndex(of: element) {
                        remove(at: index)
                    }
                }
            }
            """#,
        ])
    }

    @Test func objectiveC() {
        expect(.objectiveC, [
            #"""
            #import <Foundation/Foundation.h>

            @interface Person : NSObject
            @property (nonatomic, copy) NSString *name;
            - (void)greet;
            @end

            @implementation Person
            - (void)greet {
                NSLog(@"Hello, %@", self.name);
            }
            @end
            """#,
        ])
    }

    @Test func c() {
        expect(.c, [
            #"""
            #include <stdio.h>
            #include <stdlib.h>

            int main(int argc, char *argv[]) {
                char *buffer = malloc(sizeof(char) * 64);
                if (buffer == NULL) {
                    return 1;
                }
                printf("%s\n", argv[0]);
                free(buffer);
                return 0;
            }
            """#,
        ])
    }

    @Test func cpp() {
        expect(.cpp, [
            #"""
            #include <iostream>
            #include <vector>

            int main() {
                std::vector<int> numbers = {1, 2, 3};
                for (const auto& n : numbers) {
                    std::cout << n << std::endl;
                }
                return 0;
            }
            """#,
            #"""
            template <typename T>
            class Stack {
            public:
                void push(const T& value) { items.push_back(value); }
            private:
                std::vector<T> items;
            };
            """#,
        ])
    }

    @Test func csharp() {
        expect(.csharp, [
            #"""
            using System;
            using System.Collections.Generic;

            namespace Demo
            {
                public class Person
                {
                    public string Name { get; set; }
                    public static void Main(string[] args)
                    {
                        Console.WriteLine("Hello");
                    }
                }
            }
            """#,
        ])
    }

    @Test func java() {
        expect(.java, [
            #"""
            import java.util.ArrayList;
            import java.util.List;

            public class Main {
                public static void main(String[] args) {
                    List<String> names = new ArrayList<>();
                    names.add("Alice");
                    System.out.println(names);
                }
            }
            """#,
            #"""
            @Override
            public boolean equals(Object other) {
                if (!(other instanceof Point)) return false;
                Point p = (Point) other;
                return x == p.x && y == p.y;
            }

            @Override
            public int hashCode() {
                return Objects.hash(x, y);
            }
            """#,
        ])
    }

    @Test func kotlin() {
        expect(.kotlin, [
            #"""
            data class User(val id: Int, val name: String)

            fun main() {
                val users = listOf(User(1, "Alice"), User(2, "Bob"))
                users.forEach { println(it.name) }
            }
            """#,
            #"""
            class MainActivity : AppCompatActivity() {
                private lateinit var binding: ActivityMainBinding

                override fun onCreate(savedInstanceState: Bundle?) {
                    super.onCreate(savedInstanceState)
                    binding = ActivityMainBinding.inflate(layoutInflater)
                }
            }
            """#,
        ])
    }

    @Test func go() {
        expect(.go, [
            #"""
            package main

            import (
                "fmt"
                "os"
            )

            func main() {
                data, err := os.ReadFile("config.json")
                if err != nil {
                    fmt.Println(err)
                    return
                }
                fmt.Println(string(data))
            }
            """#,
            #"""
            func (s *Server) Start(addr string) error {
                ln, err := net.Listen("tcp", addr)
                if err != nil {
                    return err
                }
                defer ln.Close()
                return s.serve(ln)
            }
            """#,
        ])
    }

    @Test func rust() {
        expect(.rust, [
            #"""
            use std::collections::HashMap;

            fn main() {
                let mut counts: HashMap<&str, i32> = HashMap::new();
                for word in "a b a".split(' ') {
                    *counts.entry(word).or_insert(0) += 1;
                }
                println!("{:?}", counts);
            }
            """#,
            #"""
            #[derive(Debug, Clone)]
            pub struct Point {
                x: f64,
                y: f64,
            }

            impl Point {
                pub fn distance(&self, other: &Point) -> f64 {
                    ((self.x - other.x).powi(2) + (self.y - other.y).powi(2)).sqrt()
                }
            }
            """#,
        ])
    }

    @Test func javaScript() {
        expect(.javascript, [
            #"""
            const express = require('express');
            const app = express();

            app.get('/', (req, res) => {
                res.send('Hello World');
            });

            app.listen(3000, () => console.log('listening'));
            """#,
            #"""
            document.querySelector('#save').addEventListener('click', async () => {
                const response = await fetch('/api/save', { method: 'POST' });
                if (response.status !== 200) {
                    console.error('failed');
                }
            });
            """#,
        ])
    }

    @Test func typeScript() {
        expect(.typescript, [
            #"""
            interface User {
                id: number;
                name: string;
                email?: string;
            }

            export function greet(user: User): string {
                return `Hello, ${user.name}`;
            }
            """#,
            #"""
            export type Status = 'idle' | 'loading' | 'done';

            export const fetchUser = async (id: number): Promise<User> => {
                const response = await fetch(`/users/${id}`);
                return response.json();
            };
            """#,
        ])
    }

    @Test func python() {
        expect(.python, [
            #"""
            import os
            from pathlib import Path

            def list_files(root: str) -> list[str]:
                result = []
                for path in Path(root).rglob("*.py"):
                    if path.is_file():
                        result.append(str(path))
                return result

            if __name__ == "__main__":
                print(list_files(os.getcwd()))
            """#,
            #"""
            class Stack:
                def __init__(self):
                    self.items = []

                def pop(self):
                    if not self.items:
                        raise IndexError("empty")
                    return self.items.pop()
            """#,
        ])
    }

    @Test func ruby() {
        expect(.ruby, [
            #"""
            require 'json'

            class Greeter
              attr_accessor :name

              def initialize(name)
                @name = name
              end

              def greet
                puts "Hello, #{@name}!"
              end
            end
            """#,
            #"""
            [1, 2, 3].each do |n|
              puts n * 2
            end
            """#,
        ])
    }

    @Test func php() {
        expect(.php, [
            #"""
            <?php
            echo "Hello";
            """#,
            #"""
            namespace App\Http\Controllers;

            use App\Models\User;

            class UserController extends Controller
            {
                public function show($id)
                {
                    $user = User::findOrFail($id);
                    return view('user.profile', ['user' => $user]);
                }
            }
            """#,
        ])
    }

    @Test func shell() {
        expect(.shell, [
            #"""
            #!/bin/bash
            echo "hi"
            """#,
            #"""
            for file in *.png; do
                convert "$file" "${file%.png}.jpg"
            done
            """#,
            #"""
            if [ -z "$HOME" ]; then
                echo "no home" >&2
                exit 1
            fi
            """#,
            "brew install ffmpeg && ffmpeg -i input.mov -vcodec h264 output.mp4 > /dev/null 2>&1",
        ])
    }

    @Test func sql() {
        expect(.sql, [
            #"""
            SELECT u.id, u.name, COUNT(o.id) AS orders
            FROM users u
            LEFT JOIN orders o ON o.user_id = u.id
            WHERE u.created_at > '2025-01-01'
            GROUP BY u.id
            ORDER BY orders DESC;
            """#,
            "CREATE TABLE clips (id INTEGER PRIMARY KEY, text TEXT NOT NULL);",
            "select * from users where id = 42;",
        ])
    }

    @Test func markupAndData() {
        expect(.html, [
            #"""
            <div class="card">
              <h2>Title</h2>
              <p>Some text</p>
            </div>
            """#,
            "<!DOCTYPE html>\n<html><body>hi</body></html>",
        ])
        expect(.xml, [
            #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>Name</key><string>PasteMe</string></dict></plist>
            """#,
            "<config>\n  <item key=\"a\">1</item>\n  <item key=\"b\"/>\n</config>",
        ])
        expect(.css, [
            #"""
            .button {
                color: #fff;
                background: rgb(0 122 255);
                border-radius: 8px;
            }

            .button:hover {
                opacity: 0.8;
            }
            """#,
            "body { margin: 0; font-family: -apple-system, sans-serif; }",
        ])
        expect(.json, [
            #"{"name": "PasteMe", "version": 1, "tags": ["clipboard", "mac"]}"#,
            "[\n  {\"id\": 1},\n  {\"id\": 2}\n]",
        ])
        expect(.yaml, [
            #"""
            name: CI
            on:
              push:
                branches: [main]
            jobs:
              test:
                runs-on: macos-latest
                steps:
                  - uses: actions/checkout@v4
                  - run: swift test
            """#,
            "---\ntitle: Hello\ntags:\n  - a\n  - b",
        ])
    }

    @Test func proseIsNotCode() {
        for text in [
            "今天下午三点开会，请大家准时参加。会议室在三楼。",
            "这个函数（function）会返回一个列表，如果没有结果就返回空列表。\n请在提交之前运行测试。",
            "Hi John,\n\nThanks for the update. Could you send me the report by Friday?\n\nBest,\nAlice",
            "The quick brown fox jumps over the lazy dog. Then it runs away into the forest.",
            "Select the file from the menu, then choose Export.",
            "Import the photos into the library and then return to the main screen.",
            "张三: 晚上吃什么\n李四: 火锅吧\n张三: 好",
            "Alice: are you there?\nBob: yes, what's up\nAlice: let's meet at 5",
            "From: alice@example.com\nTo: bob@example.com\nSubject: Lunch",
            "f(x) = (a + b) * c - d / 2",
            "(1 + 2) * 3 = 9",
            "购物清单：\n- 牛奶\n- 面包\n- 鸡蛋",
            "TODO:\n1. Write tests\n2. Fix the bug\n3. Ship it",
            "https://example.com/path?a=1",
            "hello world",
            "ok",
        ] {
            #expect(detect(text) == nil, "\(text)")
        }
    }

    @Test func markdownIsNotCode() {
        let markdown = #"""
            # Installation

            Run the following command to install the package. It works on macOS and Linux.

            ```bash
            brew install pasteme
            ```

            Then open the app from your Applications folder.
            """#
        #expect(detect(markdown) == nil)
        #expect(detect("## Notes\n\n- First item in the list\n- Second item in the list\n\nSome closing words for this section.") == nil)
    }

    @Test func singleCommandsCountAsShellWhenCopiedFromATerminal() {
        #expect(detect("git status", from: "com.apple.Terminal") == .shell)
        #expect(detect("ls -la ~/Downloads", from: "com.googlecode.iterm2") == .shell)
        #expect(detect("$ npm install", from: "com.apple.Terminal") == .shell)
        // 别处复制的一个简单命令拿不准，不当成代码。
        #expect(detect("git status") == nil)
        // 终端里复制的输出不是命令。
        #expect(detect("On branch main\nYour branch is up to date with 'origin/main'.", from: "com.apple.Terminal") == nil)
        #expect(detect("total 48\ndrwxr-xr-x  5 lixiang  staff  160 Oct 17 10:00 Desktop", from: "com.apple.Terminal") == nil)
    }

    @Test func editorsLowerTheBar() {
        let short = "if let value { print(value) }"
        #expect(detect(short) == nil)
        #expect(detect(short, from: "com.apple.dt.Xcode") == .swift)
        #expect(detect("val items = listOf(1, 2, 3)", from: "com.jetbrains.intellij") == .kotlin)
    }

    @Test func strongOneLinersAreDetectedAnywhere() {
        #expect(detect("console.log('hello');") == .javascript)
        #expect(detect("System.out.println(\"hello\");") == .java)
        #expect(detect("fmt.Println(\"hello\")") == .go)
        #expect(detect("println!(\"hello\");") == .rust)
    }
}
