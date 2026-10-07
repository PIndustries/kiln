import Foundation
import KilnKit

public enum TerminalEffect: Equatable { case command(String), disconnect }

/// Pure session model. No networking, subprocess execution or shared mutable UI state.
public struct KilnTerminal {
    public static let enterScreen = "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?2004h\u{1b}[?25l\u{1b}[2J"
    public static let leaveScreen = "\u{1b}[0m\u{1b}[?1000l\u{1b}[?1006l\u{1b}[?2004l\u{1b}[?25h\u{1b}[?1049l"
    public private(set) var modules: [ModuleSnapshot] = []
    public private(set) var drawer = false
    public private(set) var input = ""
    public private(set) var selected = 0
    public private(set) var busy = false
    private var host: HostMetrics?
    private var cpuHistory: [Double] = []
    private var width = 80
    private var height = 24
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
        // SSH sends zero when a dimension is unknown: retain the last known value.
        let columns = width > 0 ? width : self.width
        let rows = height > 0 ? height : self.height
        // Bound total work for untrusted SSH requests, not ordinary viewport dimensions.
        guard columns <= 1_000_000 / rows else { return }
        self.width = columns
        self.height = rows
    }
    public mutating func update(_ modules: [ModuleSnapshot]) {
        let id = self.modules.indices.contains(selected) ? self.modules[selected].id : nil
        self.modules = modules
        selected = id.flatMap { id in modules.firstIndex { $0.id == id } } ?? min(selected, max(0, modules.count - 1))
    }
    public mutating func observe(_ observation: Observation) {
        update(observation.modules)
        if host?.timestamp != observation.host.timestamp, let cpu = observation.host.cpuPercent {
            cpuHistory.append(cpu); cpuHistory = Array(cpuHistory.suffix(60))
        }
        host = observation.host
    }
    private enum Click { case key(TerminalKey), service(Int), action(Int), cursor(Int) }
    private struct Hit { let row: Int; let column: Int; let width: Int; let click: Click }
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
        if case let .mouse(button, column, row, released) = key {
            guard !released, column <= width, row <= height else { return [] }
            if button == 64 { return handle(drawer ? .pageUp : .up) }
            if button == 65 { return handle(drawer ? .pageDown : .down) }
            guard button == 0 else { return [] }
            guard let hit = layout().1.last(where: { $0.row == row && column >= $0.column && column < $0.column + $0.width }) else { return [] }
            switch hit.click {
            case .key(let key):
                if row == 4 { drawer = false }
                return handle(key)
            case .service(let index): selected = index; drawer = false; return handle(.enter)
            case .action(let index): menu = index; return handle(.enter)
            case .cursor(let offset): cursor = min(input.count, max(0, offset + column - hit.column)); return []
            }
        }
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
        case .text("3"): page = 2
        case .text("4"), .text("?"): page = 3
        case .tab: page = (page + 1) % 4
        case .up, .text("k"): selected = max(0, selected - 1)
        case .down, .text("j"): selected = min(max(0, modules.count - 1), selected + 1)
        case .enter: if page < 2 && !modules.isEmpty && !busy { menu = 0 }
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
            let fixed = ["help", "status", "metrics", "app list", "app install ", "app start ", "app stop ", "app restart ", "app health ", "app logs ", "server help", "server list", "server add ", "server scan ", "server trust ", "server key ", "server exec ", "server config ", "server remove ", "key create ", "key list", "key public ", "key delete ", "exit"]
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
        case .mouse: break
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
    public func render() -> String { layout().0 }
    private func layout() -> (String, [Hit]) {
        var hits: [Hit] = []
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
            return ("\u{1b}[?25l\u{1b}[H" + (lines + Array(repeating: row(), count: max(0,height-lines.count))).prefix(height).joined(separator: "\r\n"), [])
        }
        let brand = "P.INDUSTRIES"
        var lines = [row("  " + fit("K I L N", max(0, w - brand.count - 4)) + brand, accent),
                     row("  LOCAL NODE  /  ONLINE  /  SSH SESSION", green), row()]
        let labels = width < 65 ? ["1 Home", "2 Apps", "3 Metrics", "4 Help"] : ["1 Overview", "2 Services", "3 Metrics", "4 Help"]
        var tabs = "  "
        for (index,label) in labels.enumerated() {
            let text = page == index ? "[" + label + "]" : " " + label + " "
            hits.append(Hit(row: 4, column: tabs.count+1, width: text.count, click: .key(.text(String(index+1)))))
            tabs += text + " "
        }
        lines.append(row(tabs, accent))
        lines.append(row("  " + String(repeating: "-", count: max(0,w-4)), muted))
        let bodyEnd = drawer ? max(8, height / 2) : height - 3
        if page == 3 {
            for text in ["  Click tabs, services, actions or the drawer bar.", "  Mouse wheel scrolls output or service selection.", "  Navigate", "  Up / Down or j / k    Select a service", "  Enter                 Open its action menu", "  Tab or 1 / 2 / 3 / 4  Switch views", "  ` or ~                Toggle command drawer", "  Esc                   Close drawer or menu", "  q                     Disconnect", "", "  Command drawer", "  Up / Down             Command history", "  Tab                   Complete commands and service IDs", "  Left / Right          Edit the command", "  Ctrl-A / E            Beginning / end of line", "  PgUp / PgDn           Scroll command output", "", "  Process state is not a health check."] {
                if lines.count < bodyEnd { lines.append(row(text, muted)) }
            }
        } else if page == 2 {
            let summary = host?.summary.components(separatedBy: "\n") ?? ["Waiting for the first host sample..."]
            for text in summary where lines.count < bodyEnd { lines.append(row("  " + text, fg)) }
            if lines.count < bodyEnd {
                let levels = Array("._-=+*#%@")
                let chart = String(cpuHistory.suffix(max(1,w-10)).map { levels[min(levels.count-1,Int($0/100*Double(levels.count-1)))] })
                lines.append(row("  CPU history (0-100%) " + chart, accent))
            }
            if lines.count < bodyEnd { lines.append(row("  " + fit("SERVICE",max(10,w-25)) + "  " + fit("CPU(ps)",9) + "RSS MiB", muted)) }
            let processes = [("kiln supervisor", host?.supervisorPID)] + modules.map { ($0.id,$0.pid) }
            for (name,pid) in processes where lines.count < bodyEnd {
                let metric = pid.flatMap { host?.processes[$0] }
                let cpu = metric.map { String(format: "%.1f%%", $0.cpuPercent) } ?? "--"
                let rss = metric.map { String(format: "%.1f", Double($0.residentBytes)/1_048_576) } ?? "--"
                lines.append(row("  " + fit(name,max(10,w-25)) + "  " + fit(cpu,9) + rss))
            }
        } else {
            let count = modules.filter { $0.state == "running" }.count
            lines.append(row("  \(modules.count) MODULES     \(count) RUNNING     \(modules.count-count) INACTIVE", fg))
            if page == 0 && !drawer && bodyEnd >= 17, let host {
                let cpu = host.cpuPercent.map { String(format: "%.1f%%",$0) } ?? "warming up"
                lines.append(row("  CPU " + cpu + "   RAM " + HostMetrics.bytes(host.memoryResident) + " / " + HostMetrics.bytes(host.memoryTotal), accent))
                lines.append(row("  Disk free " + HostMetrics.bytes(host.diskFree) + "   Up " + String(Int(host.uptime/3600)) + "h", muted))
            } else { lines.append(row()) }
            let versionWidth = max("VERSION".count, modules.map { $0.version.count }.max() ?? 0)
            let stateWidth = max("STATE".count, modules.map { $0.state.count }.max() ?? 0)
            let pidWidth = max("PID".count, modules.map { $0.pid.map(String.init)?.count ?? 1 }.max() ?? 0)
            let metadataWidth = versionWidth + stateWidth + pidWidth + 6
            let wide = w - 4 - metadataWidth >= max("SERVICE".count, (w - 4) / 3)
            let nameWidth = max(1, w - 4 - (wide ? metadataWidth : stateWidth + 2))
            let header = "  " + fit("SERVICE", nameWidth) + "  " + (wide ? fit("VERSION",versionWidth) + "  " + fit("STATE",stateWidth) + "  " + fit("PID",pidWidth) : fit("STATE",stateWidth))
            lines.append(row(header, muted))
            let detailRows = page == 0 && !drawer && bodyEnd - lines.count >= 8 ? 7 : 0
            let capacity = max(1, bodyEnd - lines.count - detailRows)
            let offset = max(0, selected - capacity + 1)
            if modules.isEmpty { lines.append(row("  No services installed. Open ` and use app install.", muted)) }
            for index in offset..<min(modules.count, offset + capacity) {
                let module = modules[index]
                let marker = index == selected ? "> " : "  "
                let text = marker + fit(module.id,nameWidth) + "  " + (wide ? fit(module.version,versionWidth) + "  " + fit(module.state,stateWidth) + "  " + fit(module.pid.map(String.init) ?? "-",pidWidth) : fit(module.state,stateWidth))
                hits.append(Hit(row: lines.count+1, column: 1, width: w, click: .service(index)))
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
            hits.append(Hit(row: lines.count, column: 1, width: w, click: .key(.text("`"))))
            hits.append(Hit(row: lines.count+1, column: 1, width: w, click: .key(.text("`"))))
            lines.append(row("  COMMAND DRAWER   \(busy ? "[working]" : "[ready]")   Esc / ` to close", accent))
            let available = max(0, height - lines.count - 3)
            let end = max(0, transcript.count - scroll)
            let visible = Array(transcript.prefix(end).suffix(available))
            for text in visible { lines.append(row("  " + text, text.hasPrefix("Error") ? red : fg)) }
            while lines.count < height - 3 { lines.append(row()) }
            let room = max(1,w-9)
            let offset = max(0, cursor - room + 1)
            let shown = String(Array(input).dropFirst(offset).prefix(room))
            hits.append(Hit(row: height-2, column: 10, width: room, click: .cursor(offset)))
            lines.append(row("  kiln > " + shown, accent))
            lines.append(row("  Tab complete  |  Up/Down history  |  PgUp/PgDn output", muted))
            lines.append(row("  " + notice, muted))
            let cursorColumn = min(w, 10 + cursor - offset)
            return ("\u{1b}[?25l\u{1b}[H" + lines.prefix(height).joined(separator: "\r\n") + "\u{1b}[\(height-2);\(cursorColumn)H\u{1b}[?25h", hits)
        }
        lines.append(row("  " + notice, muted))
        lines.append(row("  Click/Enter manage | ` drawer | ? help | q exit", accent))
        let sampled = host.map { String($0.timestamp.ISO8601Format().suffix(9)) } ?? "waiting"
        lines.append(row("  LIVE 1s / " + sampled + " / process state != health", muted))
        hits.append(Hit(row: height-1, column: 1, width: w, click: .key(.text("`"))))
        var overlay = ""
        if let action = menu, modules.indices.contains(selected),
           let anchor = hits.first(where: {
               if case .service(let index) = $0.click { return index == selected }
               return false
           }) {
            let title = confirmation.map { "Confirm: " + $0 + " ?" } ?? "Manage " + modules[selected].id
            let choices = confirmation != nil ? ["Enter confirm   /   Esc cancel"] : actions.enumerated().map {
                "\($0.offset == action ? ">" : " ") " + $0.element
            }
            let panelWidth = min(w - 4, max(title.count, choices.map(\.count).max() ?? 0) + 4)
            let panelHeight = choices.count + 3
            // Anchor to the visible service row, including scrolling and resize.
            // Shift left/up only when the popup would cross the viewport edge.
            let left = min(4 + Self.safe(modules[selected].id).count, w - panelWidth + 1)
            let top = max(1, min(anchor.row, bodyEnd - panelHeight + 1))
            let border = "+" + String(repeating: "-", count: panelWidth - 2) + "+"
            let panel = [border, "| " + fit(title, panelWidth - 4) + " |"]
                + choices.map { "| " + fit($0, panelWidth - 4) + " |" } + [border]
            hits = []
            for (index, text) in panel.enumerated() {
                let color = index <= 1 || index == panel.count - 1 || (confirmation == nil && index == action + 2) ? accent : fg
                overlay += "\u{1b}[\(top + index);\(left)H\u{1b}[0m\u{1b}[48;5;238m" + color + text + "\u{1b}[0m"
                if index >= 2 && index < panel.count - 1 {
                    if confirmation != nil {
                        hits.append(Hit(row: top + index, column: left + 2, width: 13, click: .key(.enter)))
                        hits.append(Hit(row: top + index, column: left + 20, width: 10, click: .key(.escape)))
                    } else {
                        hits.append(Hit(row: top + index, column: left + 1, width: panelWidth - 2, click: .action(index - 2)))
                    }
                }
            }
        }
        return ("\u{1b}[?25l\u{1b}[H" + lines.prefix(height).joined(separator: "\r\n") + overlay, hits)
    }
}
