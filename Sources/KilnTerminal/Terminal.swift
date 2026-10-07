import Foundation
import KilnKit

public enum TerminalEffect: Equatable { case command(String), disconnect }

/// Pure session model. No networking, subprocess execution or shared mutable UI state.
public struct KilnTerminal {
    public static let enterScreen = "\u{1b}[?1049h\u{1b}[?2004h\u{1b}[?25l\u{1b}[2J"
    public static let leaveScreen = "\u{1b}[0m\u{1b}[?2004l\u{1b}[?25h\u{1b}[?1049l"
    public private(set) var modules: [ModuleSnapshot] = []
    public private(set) var drawer = false
    public private(set) var input = ""
    public private(set) var selected = 0
    public private(set) var busy = false
    private var width = 100
    private var height = 30
    private var page = 0
    private var cursor = 0
    private var history: [String] = []
    private var historyPosition: Int?
    private var draft = ""
    private var transcript: [String] = ["Command drawer ready. Type help, or use Tab to complete."]
    private var scroll = 0
    private var menu: Int? = nil
    private var confirmation: String? = nil
    private var notice = "Select a service and press Enter to manage it."
    private let actions = ["Start", "Stop", "Restart", "Check health", "View logs", "Back"]
    public init() {}
    public mutating func resize(width: Int, height: Int) {
        self.width = min(240, max(20, width > 0 ? width : 100))
        self.height = min(100, max(6, height > 0 ? height : 30))
    }
    public mutating func update(_ modules: [ModuleSnapshot]) {
        let id = self.modules.indices.contains(selected) ? self.modules[selected].id : nil
        self.modules = modules
        selected = id.flatMap { id in modules.firstIndex { $0.id == id } } ?? min(selected, max(0, modules.count - 1))
    }
    public mutating func finish(text: String, status: Int) {
        busy = false
        let lines = text.components(separatedBy: "\n")
        transcript += lines
        transcript = Array(transcript.suffix(300)); scroll = 0
        notice = status == 0 ? (lines.count > 1 ? "Command completed. Output is in the drawer." : lines.first ?? "Done") : "Failed: " + (lines.first ?? "Unknown error")
    }
    private mutating func execute(_ command: String) -> [TerminalEffect] {
        guard !busy else { return [] }
        busy = true; scroll = 0; transcript.append("> " + command)
        notice = "Working: " + command
        return [.command(command)]
    }
    public mutating func handle(_ key: TerminalKey) -> [TerminalEffect] {
        if key == .text("`") || key == .text("~") {
            drawer.toggle(); menu = nil; confirmation = nil; return []
        }
        if drawer { return edit(key) }
        if key == .eof || key == .text("q") { return [.disconnect] }
        if key == .escape || key == .interrupt { menu = nil; confirmation = nil; return [] }
        if let command = confirmation {
            if key == .enter { confirmation = nil; menu = nil; return execute(command) }
            return []
        }
        if let action = menu {
            switch key {
            case .up: menu = (action + actions.count - 1) % actions.count
            case .down: menu = (action + 1) % actions.count
            case .enter:
                guard modules.indices.contains(selected) else { menu = nil; return [] }
                let id = modules[selected].id
                switch action {
                case 0: menu = nil; return execute("app start " + id)
                case 1: confirmation = "app stop " + id
                case 2: confirmation = "app restart " + id
                case 3: menu = nil; return execute("app health " + id)
                case 4: menu = nil; drawer = true; return execute("app logs " + id)
                default: menu = nil
                }
            default: break
            }
            return []
        }
        switch key {
        case .text("1"): page = 0
        case .text("2"): page = 1
        case .text("3"), .text("?"): page = 2
        case .tab: page = (page + 1) % 3
        case .up, .text("k"): selected = max(0, selected - 1)
        case .down, .text("j"): selected = min(max(0, modules.count - 1), selected + 1)
        case .enter: if page != 2 && !modules.isEmpty && !busy { menu = 0 }
        default: break
        }
        return []
    }
    private mutating func edit(_ key: TerminalKey) -> [TerminalEffect] {
        var characters = Array(input)
        switch key {
        case .escape: drawer = false
        case .interrupt: input = ""; cursor = 0; historyPosition = nil
        case .eof: if input.isEmpty { drawer = false }
        case .text(let text):
            if input.utf8.count + text.utf8.count <= 4096 {
                characters.insert(contentsOf: Array(text), at: cursor); cursor += text.count; input = String(characters)
            }
        case .paste(let text):
            let safe = text.components(separatedBy: .newlines).joined(separator: " ").filter { !$0.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
            let addition = String(safe.prefix(max(0, 4096 - input.utf8.count)))
            characters.insert(contentsOf: Array(addition), at: cursor); cursor += addition.count; input = String(characters)
        case .left: cursor = max(0, cursor - 1)
        case .right: cursor = min(characters.count, cursor + 1)
        case .home: cursor = 0
        case .end: cursor = characters.count
        case .backspace: if cursor > 0 { characters.remove(at: cursor - 1); cursor -= 1; input = String(characters) }
        case .delete: if cursor < characters.count { characters.remove(at: cursor); input = String(characters) }
        case .clearBefore: input = String(characters.dropFirst(cursor)); cursor = 0
        case .clearAfter: input = String(characters.prefix(cursor))
        case .up:
            if !history.isEmpty {
                if historyPosition == nil { draft = input }
                historyPosition = max(0, (historyPosition ?? history.count) - 1)
                input = history[historyPosition!]; cursor = input.count
            }
        case .down:
            if let position = historyPosition {
                if position + 1 < history.count { historyPosition = position + 1; input = history[position + 1] }
                else { historyPosition = nil; input = draft }
                cursor = input.count
            }
        case .tab:
            let fixed = ["help", "status", "app list", "app install ", "app start ", "app stop ", "app restart ", "app health ", "app logs ", "exit"]
            let expanded = ["start", "stop", "restart", "health", "logs"].flatMap { operation in modules.map { "app \(operation) \($0.id)" } }
            let matches = (fixed + expanded).filter { $0.hasPrefix(input) && $0 != input }
            if matches.count == 1 { input = matches[0]; cursor = input.count }
            else if !matches.isEmpty {
                var common = matches[0]
                for candidate in matches.dropFirst() { while !candidate.hasPrefix(common) { common.removeLast() } }
                if common.count > input.count { input = common; cursor = input.count }
                else { transcript += matches; transcript = Array(transcript.suffix(300)) }
            }
        case .pageUp: scroll = min(max(0, transcript.count - 1), scroll + 5)
        case .pageDown: scroll = max(0, scroll - 5)
        case .enter:
            guard !busy else { return [] }
            let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { return [] }
            if history.last != command { history.append(command); history = Array(history.suffix(100)) }
            input = ""; cursor = 0; historyPosition = nil
            return execute(command)
        }
        return []
    }

    // Values from logs/errors are untrusted terminal content. Only printable ASCII
    // is emitted in cells; this also guarantees deterministic single-column widths.
    public static func safe(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar -> Character in
            if scalar.value >= 32 && scalar.value <= 126 { return Character(String(scalar)) }
            return scalar.value == 9 ? " " : "?"
        })
    }
    public func render() -> String {
        let w = width - 1
        let bg = "\u{1b}[48;5;234m", fg = "\u{1b}[38;5;252m"
        let muted = "\u{1b}[38;5;245m", accent = "\u{1b}[38;5;215m"
        let green = "\u{1b}[38;5;114m", red = "\u{1b}[38;5;203m"
        func fit(_ text: String, _ n: Int) -> String {
            let clean = Self.safe(text)
            guard n > 0 else { return "" }
            if clean.count > n { return String(clean.prefix(max(0,n-1))) + "~" }
            return clean.padding(toLength: n, withPad: " ", startingAt: 0)
        }
        func row(_ text: String = "", _ color: String = "", selected: Bool = false) -> String {
            "\u{1b}[0m" + (selected ? "\u{1b}[48;5;238m" : bg) + fg + color + fit(text, w) + "\u{1b}[0m"
        }
        if width < 50 || height < 16 {
            let lines = [row(" KILN / P.Industries", accent), row(" Terminal too small", accent), row(" Resize to at least 50 columns x 16 rows."), row(" Current: \(width) x \(height)", muted), row(" Ctrl-D disconnects", muted)]
            return "\u{1b}[?25l\u{1b}[H" + (lines + Array(repeating: row(), count: max(0,height-lines.count))).prefix(height).joined(separator: "\r\n")
        }
        var lines = [row("  K I L N                                      P.INDUSTRIES", accent),
                     row("  LOCAL NODE  /  ONLINE  /  SSH SESSION", green), row()]
        lines.append(row("  \(page == 0 ? "[1 Overview]" : " 1 Overview ")  \(page == 1 ? "[2 Services]" : " 2 Services ")  \(page == 2 ? "[3 Help]" : " 3 Help ")", accent))
        lines.append(row("  " + String(repeating: "-", count: max(0,w-4)), muted))
        let bodyEnd = drawer ? max(8, height / 2) : height - 3
        if page == 2 {
            for text in ["  Navigate", "  Up / Down or j / k    Select a service", "  Enter                 Open its action menu", "  Tab or 1 / 2 / 3      Switch views", "  ` or ~                Toggle command drawer", "  Esc                   Close drawer or menu", "  q                     Disconnect", "", "  Command drawer", "  Up / Down             Command history", "  Tab                   Complete commands and service IDs", "  Left / Right          Edit the command", "  Ctrl-A / E            Beginning / end of line", "  PgUp / PgDn           Scroll command output", "", "  Process state is not a health check."] {
                if lines.count < bodyEnd { lines.append(row(text, muted)) }
            }
        } else {
            let count = modules.filter { $0.state == "running" }.count
            lines.append(row("  \(modules.count) MODULES     \(count) RUNNING     \(modules.count-count) INACTIVE", fg))
            lines.append(row())
            let nameWidth = max(12, w - 39)
            let wide = width >= 75
            let header = wide ? "  " + fit("SERVICE", nameWidth) + "  " + fit("VERSION",10) + "  " + fit("STATE",9) + "  PID" : "  " + fit("SERVICE",w-15) + " STATE"
            lines.append(row(header, muted))
            let capacity = max(1, page == 0 && !drawer ? min(5, bodyEnd - lines.count - 8) : bodyEnd - lines.count)
            let offset = max(0, selected - capacity + 1)
            if modules.isEmpty { lines.append(row("  No services installed. Open ` and use app install.", muted)) }
            for index in offset..<min(modules.count, offset + capacity) {
                let module = modules[index]
                let marker = index == selected ? "> " : "  "
                let text = wide ? marker + fit(module.id,nameWidth) + "  " + fit(module.version,10) + "  " + fit(module.state,9) + "  " + (module.pid.map(String.init) ?? "-") : marker + fit(module.id,w-15) + " " + module.state
                lines.append(row(text, module.state == "running" ? green : muted, selected: index == selected))
            }
            if page == 0 && !drawer && modules.indices.contains(selected) && bodyEnd - lines.count >= 7 {
                let module = modules[selected]
                lines.append(row())
                lines.append(row("  SELECTED SERVICE", accent))
                lines.append(row("  " + module.id, fg))
                lines.append(row("  Release  " + module.version + "     Process  " + (module.pid.map(String.init) ?? "not running"), muted))
                lines.append(row("  Process state: " + module.state, module.state == "running" ? green : muted))
                lines.append(row("  Health: use Check health in the action menu", muted))
                lines.append(row("  [ Enter: start / stop / restart / health / logs ]", accent))
            }
        }
        lines = Array(lines.prefix(bodyEnd))
        while lines.count < bodyEnd { lines.append(row()) }
        if drawer {
            lines.append(row("  " + String(repeating: "=", count: max(0, w - 4)), accent))
            lines.append(row("  COMMAND DRAWER   \(busy ? "[working]" : "[ready]")   Esc / ` to close", accent))
            let available = max(0, height - lines.count - 3)
            let end = max(0, transcript.count - scroll)
            let visible = Array(transcript.prefix(end).suffix(available))
            for text in visible { lines.append(row("  " + text, text.hasPrefix("Error") ? red : fg)) }
            while lines.count < height - 3 { lines.append(row()) }
            let room = max(1,w-9)
            let offset = max(0, cursor - room + 1)
            let shown = String(Array(input).dropFirst(offset).prefix(room))
            lines.append(row("  kiln > " + shown, accent))
            lines.append(row("  Tab complete  |  Up/Down history  |  PgUp/PgDn output", muted))
            lines.append(row("  " + notice, muted))
            let cursorColumn = min(w, 10 + cursor - offset)
            return "\u{1b}[?25l\u{1b}[H" + lines.prefix(height).joined(separator: "\r\n") + "\u{1b}[\(height-2);\(cursorColumn)H\u{1b}[?25h"
        }
        lines.append(row("  " + notice, muted))
        lines.append(row("  Enter manage  |  ` command drawer  |  ? help  |  q exit", accent))
        lines.append(row("  Single node   /   refresh 2s   /   health checked on demand", muted))
        if let action = menu {
            let title = confirmation != nil ? "  Confirm: " + confirmation! + " ?" : "  Manage " + (modules.indices.contains(selected) ? modules[selected].id : "service")
            let top = max(5, (height - 9)/2)
            let panel = [row(title, accent, selected: true)] + (confirmation != nil ? [row("  Enter confirm   /   Esc cancel", fg, selected: true)] : actions.enumerated().map { i, name in row("  \(i == action ? ">" : " ") " + name, i == action ? accent : fg, selected: true) })
            for (index,line) in panel.enumerated() where top+index < lines.count-2 { lines[top+index] = line }
        }
        return "\u{1b}[?25l\u{1b}[H" + lines.prefix(height).joined(separator: "\r\n")
    }
}
