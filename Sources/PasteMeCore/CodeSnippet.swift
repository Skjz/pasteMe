import Foundation

/// 代码卡片上显示的部分（#28）：等宽字体、保留缩进、长行在右边截断，不换行。
public enum CodeSnippet {
    /// 前 `maxLines` 行（不算开头的空行），tab 换成 4 个空格，去掉这几行共同的缩进和行尾空白。
    /// 从函数中间复制的代码整体缩进了几层，不去掉的话卡片上大半是空白。
    public static func displayText(_ text: String, maxLines: Int) -> String {
        var lines: [String] = []
        // `\r\n` 在 Swift 里是一个字符，按 `\n` 切不开。
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var expanded = line.replacingOccurrences(of: "\t", with: "    ")
            while let last = expanded.last, last == " " || last == "\r" { expanded.removeLast() }
            if lines.isEmpty, expanded.isEmpty { continue }
            lines.append(expanded)
            if lines.count == maxLines { break }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        let indent = lines.filter { !$0.isEmpty }.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        return lines.map { $0.isEmpty ? $0 : String($0.dropFirst(indent)) }.joined(separator: "\n")
    }

    /// 着色后的片段，每行超过 `maxColumns` 列的部分截掉，末尾换成「…」。中日韩文字和 emoji 算两列。
    public static func truncating(_ segments: [SyntaxHighlighter.Segment], maxColumns: Int) -> [SyntaxHighlighter.Segment] {
        // 先按整段文字算出每行留几个字符，nil 表示整行都放得下。
        let plain = segments.map(\.text).joined()
        let keep: [Int?] = plain.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard line.reduce(0, { $0 + columns(of: $1) }) > maxColumns else { return nil }
            var used = 0
            var count = 0
            for character in line {
                let width = columns(of: character)
                if used + width > maxColumns - 1 { break }
                used += width
                count += 1
            }
            return count
        }
        guard keep.contains(where: { $0 != nil }) else { return segments }

        var result: [SyntaxHighlighter.Segment] = []
        func append(_ text: String, _ kind: SyntaxHighlighter.Kind?) {
            guard !text.isEmpty else { return }
            if let last = result.last, last.kind == kind {
                result[result.count - 1].text += text
            } else {
                result.append(SyntaxHighlighter.Segment(text, kind))
            }
        }
        var line = 0
        var index = 0
        for segment in segments {
            var piece = ""
            for character in segment.text {
                if character == "\n" {
                    piece.append(character)
                    line += 1
                    index = 0
                    continue
                }
                defer { index += 1 }
                guard let limit = keep[line] else {
                    piece.append(character)
                    continue
                }
                if index < limit {
                    piece.append(character)
                } else if index == limit {
                    append(piece, segment.kind)
                    piece = ""
                    append("…", nil)
                }
            }
            append(piece, segment.kind)
        }
        return result
    }

    /// 等宽字体里占几列：中日韩文字、全角符号和 emoji 两列，其余一列。
    static func columns(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1FAFF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}
