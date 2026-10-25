import Foundation

extension KilnTerminal {
    /// Position an independently rendered chat pane without allowing its lines to
    /// wrap through the code pane. All text has already passed terminal sanitizing.
    static func positionPane(_ frame: String, column: Int) -> String {
        let pattern = try! NSRegularExpression(pattern: "\\u001B\\[(?:(\\d+);(\\d+))?H")
        var result = frame
        for match in pattern.matches(in: frame, range: NSRange(frame.startIndex..., in: frame)).reversed() {
            let row = Range(match.range(at: 1), in: frame).flatMap { Int(frame[$0]) } ?? 1
            let col = Range(match.range(at: 2), in: frame).flatMap { Int(frame[$0]) } ?? 1
            if let range = Range(match.range, in: result) { result.replaceSubrange(range, with: "\u{1b}[\(row);\(col+column)H") }
        }
        let rows = result.components(separatedBy: "\r\n")
        return rows.enumerated().map { index, line in
            (index == 0 ? "" : "\u{1b}[\(index+1);\(column+1)H") + line
        }.joined()
    }
}
