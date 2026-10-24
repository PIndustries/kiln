import Foundation

/// Validated terminal colors, restricted to ANSI palette indices (never raw escape input).
public struct TerminalTheme: Codable, Sendable, Equatable {
    public private(set) var accent = 46
    public private(set) var background = 0
    public private(set) var foreground = 252
    public private(set) var muted = 245
    public var accentCode: String { "\u{1b}[38;5;\(accent)m" }
    public var backgroundCode: String { "\u{1b}[48;5;\(background)m" }
    public var foregroundCode: String { "\u{1b}[38;5;\(foreground)m" }
    public var mutedCode: String { "\u{1b}[38;5;\(muted)m" }

    public init() {}
    private init(accent: Int, background: Int = 0, foreground: Int = 252, muted: Int = 245) {
        self.accent = accent; self.background = background; self.foreground = foreground; self.muted = muted
    }
    private enum CodingKeys: String, CodingKey { case accent, background, foreground, muted }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let colors = try [CodingKeys.accent, .background, .foreground, .muted].map { try container.decode(Int.self, forKey: $0) }
        guard colors.allSatisfy({ (0...255).contains($0) }), Set(colors).count == 4 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid terminal palette"))
        }
        self.init(accent: colors[0], background: colors[1], foreground: colors[2], muted: colors[3])
    }

    public static func parse(_ arguments: [String]) -> Self? {
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
