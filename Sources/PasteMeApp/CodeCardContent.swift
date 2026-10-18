import AppKit
import PasteMeCore
import SwiftUI

/// 代码卡片的正文（#28）：等宽字体、按词法着色，只显示前几行，长行在右边截断、不换行。
/// `language` 为 nil 时不着色，hexdump 卡片用它对齐。
///
/// 着色结果按条目和深浅外观缓存（`CodeHighlightCache`）。外观换了以后视图读到新的 `colorScheme`，
/// 取另一份结果，所以颜色跟着变（不会像 #18 那样沿用旧外观画好的结果）。
struct CodeCardContent: View {
    let item: ClipItem
    let language: CodeLanguage?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(CodeHighlightCache.text(for: item, language: language, dark: colorScheme == .dark))
            .font(CodeHighlightCache.font)
            .lineLimit(CodeHighlightCache.maxLines)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

@MainActor
enum CodeHighlightCache {
    static let fontSize: CGFloat = 11
    static let font = Font.system(size: fontSize, design: .monospaced)
    static let maxLines = 11

    /// 卡片正文一行能放下几列。行比这长就截断：文字超出卡片、靠卡片的圆角裁掉的话，
    /// 每张卡片在依次出现的动画里都要逐帧重新合成（见 `ClipCardView.headerIcon`）。
    static let maxColumns: Int = {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
        return Int((ClipCardView.size.width - 20) / advance)
    }()

    private struct Key: Hashable {
        let id: Int64
        let preview: String?
        let language: CodeLanguage?
        let dark: Bool
    }

    private static var cache: [Key: AttributedString] = [:]

    static func text(for item: ClipItem, language: CodeLanguage?, dark: Bool) -> AttributedString {
        let key = Key(id: item.id, preview: item.preview, language: language, dark: dark)
        if let cached = cache[key] { return cached }
        // 面板最多显示几百张卡片，超过就从头再来，不留着删掉的条目。
        if cache.count > 600 { cache.removeAll() }
        let display = CodeSnippet.displayText(item.preview ?? "", maxLines: maxLines)
        let segments = CodeSnippet.truncating(
            language.map { SyntaxHighlighter.segments(of: display, language: $0) } ?? [SyntaxHighlighter.Segment(display, nil)],
            maxColumns: maxColumns
        )
        var result = AttributedString()
        for segment in segments {
            var part = AttributedString(segment.text)
            if let kind = segment.kind {
                part.foregroundColor = CodePalette.color(kind, dark: dark)
            }
            result += part
        }
        cache[key] = result
        return result
    }
}

/// 着色用的颜色，按 Xcode 默认主题的浅色和深色版本取。
enum CodePalette {
    static func color(_ kind: SyntaxHighlighter.Kind, dark: Bool) -> Color {
        let (light, darkRGB) = rgb(kind)
        let (r, g, b) = dark ? darkRGB : light
        return Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    private static func rgb(_ kind: SyntaxHighlighter.Kind) -> ((Int, Int, Int), (Int, Int, Int)) {
        switch kind {
        case .keyword, .tag: ((155, 35, 147), (252, 95, 163))
        case .string: ((196, 26, 22), (252, 106, 93))
        case .number: ((28, 0, 207), (208, 191, 105))
        case .comment: ((93, 108, 121), (127, 140, 152))
        case .type: ((108, 54, 169), (208, 168, 255))
        case .function: ((50, 109, 116), (103, 183, 164))
        case .attribute: ((129, 95, 3), (253, 143, 63))
        case .property: ((15, 104, 160), (93, 216, 255))
        case .variable: ((92, 38, 153), (161, 103, 230))
        }
    }
}
