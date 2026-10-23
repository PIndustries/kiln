import Foundation

/// Session-local colors, restricted to ANSI palette indices (never raw escape input).
struct TerminalTheme {
    var accent = 46
    var background = 0
    var foreground = 252
    var muted = 245
    var accentCode: String { "\u{1b}[38;5;\(accent)m" }
    var backgroundCode: String { "\u{1b}[48;5;\(background)m" }
    var foregroundCode: String { "\u{1b}[38;5;\(foreground)m" }
    var mutedCode: String { "\u{1b}[38;5;\(muted)m" }

    static func parse(_ arguments: [Substring]) -> Self? {
        if arguments.count == 1 {
            switch arguments[0] {
            case "green", "default": return Self()
            case "cyan": return Self(accent: 51)
            case "amber": return Self(accent: 215)
            case "mono": return Self(accent: 255)
            default: return nil
            }
        }
        guard arguments.count == 5, arguments[0] == "custom" else { return nil }
        let colors = arguments.dropFirst().compactMap { Int($0) }
        guard colors.count == 4, colors.allSatisfy({ (0...255).contains($0) }),
              Set(colors).count == 4 else { return nil }
        return Self(accent: colors[0], background: colors[1], foreground: colors[2], muted: colors[3])
    }
}
