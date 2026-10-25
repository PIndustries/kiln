import Foundation

/// Small deterministic lexer: source never supplies terminal control sequences.
/// Colors apply after sanitizing text, so highlighting cannot alter cell geometry.
struct SourceSyntax {
    private var blockComment = 0
    private var quote: Character?
    private var triple = false
    private let keywords = Set("actor async await break case catch class continue default defer do else enum extension fallthrough false fileprivate for func guard if import in init inout internal is let nil nonisolated open override private protocol public repeat rethrows return self some static struct subscript super switch throw throws true try typealias var weak where while const function export from new typeof null undefined interface async await document".split(separator: " ").map(String.init))
    mutating func colors(_ text: String, path: String) -> [Int?] {
        let a = Array(text); var colors = [Int?](repeating: nil, count: a.count), i = 0
        let markup = ["html", "svg"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
        func matches(_ value: String, at index: Int) -> Bool { let chars = Array(value); return index + chars.count <= a.count && Array(a[index..<index+chars.count]) == chars }
        func paint(_ start: Int, _ end: Int, _ color: Int) { for n in start..<min(end,a.count) { colors[n] = color } }
        while i < a.count {
            if blockComment > 0 {
                if matches("/*", at: i) { blockComment += 1; paint(i,i+2,244); i += 2 }
                else if matches("*/", at: i) { blockComment -= 1; paint(i,i+2,244); i += 2 }
                else { colors[i] = 244; i += 1 }
            } else if let q = quote {
                if triple && matches("\"\"\"", at: i) { paint(i,i+3,114); i += 3; quote = nil; triple = false }
                else if !triple && a[i] == q { colors[i] = 114; i += 1; quote = nil }
                else if a[i] == "\\", i+1 < a.count { paint(i,i+2,114); i += 2 }
                else { colors[i] = 114; i += 1 }
            } else if matches("//", at: i) { paint(i,a.count,244); break }
            else if matches("/*", at: i) { blockComment = 1; paint(i,i+2,244); i += 2 }
            else if matches("\"\"\"", at: i) { quote = "\""; triple = true; paint(i,i+3,114); i += 3 }
            else if a[i] == "\"" || a[i] == "'" || a[i] == "`" { quote = a[i]; colors[i] = 114; i += 1 }
            else if a[i].isNumber {
                let start = i; i += 1
                while i < a.count && (a[i].isNumber || a[i] == "." || a[i] == "_") { i += 1 }
                paint(start,i,221)
            } else if a[i].isLetter || a[i] == "_" || a[i] == "@" {
                let start = i; i += 1
                while i < a.count && (a[i].isLetter || a[i].isNumber || a[i] == "_") { i += 1 }
                let word = String(a[start..<i])
                if keywords.contains(word) || word.hasPrefix("@") { paint(start,i,141) }
                else if markup || a[start].isUppercase { paint(start,i,81) }
            } else {
                if markup && (a[i] == "<" || a[i] == ">" || a[i] == "/") { colors[i] = 81 }
                i += 1
            }
        }
        if !triple { quote = nil }
        return colors
    }
    static func styled(_ text: String, colors: [Int?], base: Int) -> String {
        var output = "", last = base
        for (index, character) in text.enumerated() {
            let color = index < colors.count ? colors[index] ?? base : base
            if color != last { output += "\u{1b}[38;5;\(color)m"; last = color }
            output.append(character)
        }
        if last != base { output += "\u{1b}[38;5;\(base)m" }
        return output
    }
}
