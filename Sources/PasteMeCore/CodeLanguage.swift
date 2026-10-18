import Foundation

/// 代码卡片识别和着色的编程语言（#28）。`rawValue` 存在 `text_subtype` 里（`code:swift`），不要改。
public enum CodeLanguage: String, CaseIterable, Sendable {
    case swift
    case objectiveC = "objc"
    case c
    case cpp
    case csharp
    case java
    case kotlin
    case go
    case rust
    case javascript
    case typescript
    case python
    case ruby
    case php
    case shell
    case sql
    case html
    case xml
    case css
    case json
    case yaml

    public var title: String {
        switch self {
        case .swift: "Swift"
        case .objectiveC: "Objective-C"
        case .c: "C"
        case .cpp: "C++"
        case .csharp: "C#"
        case .java: "Java"
        case .kotlin: "Kotlin"
        case .go: "Go"
        case .rust: "Rust"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .python: "Python"
        case .ruby: "Ruby"
        case .php: "PHP"
        case .shell: "Shell"
        case .sql: "SQL"
        case .html: "HTML"
        case .xml: "XML"
        case .css: "CSS"
        case .json: "JSON"
        case .yaml: "YAML"
        }
    }
}
