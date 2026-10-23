import Foundation
import KilnKit

public enum TerminalEffect: Equatable { case command(String), disconnect, selectText(Bool) }

/// Pure session model. No networking, subprocess execution or shared mutable UI state.
public struct KilnTerminal {
    public static let enterScreen = "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?2004h\u{1b}[?25l\u{1b}[2J"
    public static let leaveScreen = "\u{1b}[0m\u{1b}[?1000l\u{1b}[?1006l\u{1b}[?2004l\u{1b}[?25h\u{1b}[?1049l"
    public private(set) var modules: [ModuleSnapshot] = []
    public private(set) var drawer = false
    public private(set) var input = ""
    public private(set) var selected = 0
    public private(set) var busy = false
    private var management = ManagementUI()
    private var accessLabel: String?
    private var aiWorkspace = AIWorkspaceSnapshot()
    private var sidebarFocus = false
    private var sidebarSelected = 0
    private var reviewID: String?
    private var reviewButton = 0
    public mutating func updateAIWorkspace(_ snapshot: AIWorkspaceSnapshot) {
        let selectedID = workspaceItems.indices.contains(sidebarSelected) ? workspaceItems[sidebarSelected].id : nil
        aiWorkspace = snapshot
        sidebarSelected = selectedID.flatMap { id in workspaceItems.firstIndex { $0.id == id } } ?? min(sidebarSelected, max(0, workspaceItems.count - 1))
    }
    private struct WorkspaceItem { let id: String; let title: String; let subtitle: String; let approval: Bool }
    private var workspaceItems: [WorkspaceItem] {
        aiWorkspace.proposals.map { WorkspaceItem(id: $0.id, title: "APPROVAL / " + $0.operation, subtitle: $0.module, approval: true) } +
        aiWorkspace.tasks.map { WorkspaceItem(id: $0.id, title: "TASK / " + $0.status, subtitle: $0.prompt, approval: false) }
    }
    private mutating func chooseWorkspace(_ index: Int) -> [TerminalEffect] {
        guard !busy, workspaceItems.indices.contains(index) else { return [] }
        sidebarSelected = index
        let item = workspaceItems[index]
        if item.approval { reviewID = item.id; reviewButton = 0; sidebarFocus = false; return [] }
        sidebarFocus = false; reviewID = nil
        return execute("ai task show " + Self.quote(item.id))
    }
    private mutating func reviewAction(_ action: Int) -> [TerminalEffect] {
        guard !busy, let id = reviewID else { return [] }
        if action == 2 { reviewID = nil; return [] }
        guard aiWorkspace.proposals.contains(where: { $0.id == id && $0.expires > Date() }) else { return [] }
        reviewID = nil; sidebarFocus = false
        return execute("ai " + (action == 0 ? "approve " : "deny ") + Self.quote(id))
    }
    private var servers: [ServerSnapshot] = []
    private var selectedServer = 0
    public mutating func updateServers(_ servers: [ServerSnapshot], keys: [String]) {
        let name = self.servers.indices.contains(selectedServer) ? self.servers[selectedServer].name : nil
        self.servers = servers; management.servers = servers; management.keys = keys
        selectedServer = name.flatMap { name in servers.firstIndex { $0.name == name } } ?? min(selectedServer,max(0,servers.count-1))
    }
    public mutating func updateManagement(_ snapshot: ManagementSnapshot) {
        accessLabel = snapshot.access
        if let error = snapshot.error {
            // Permission revocation must also remove stale management inventory.
            updateSessions([]); updateServers([], keys: [])
            if page == 4 || page == 5 { notice = error }
            return
        }
        updateSessions(snapshot.sessions); updateServers(snapshot.servers,keys:snapshot.keys)
    }
    private var sessions: [TerminalSessionSnapshot] = []
    private var selectedSession = 0
    public mutating func updateSessions(_ sessions: [TerminalSessionSnapshot]) {
        let name = self.sessions.indices.contains(selectedSession) ? self.sessions[selectedSession].name : nil
        self.sessions = sessions
        selectedSession = name.flatMap { name in sessions.firstIndex { $0.name == name } } ?? min(selectedSession, max(0, sessions.count - 1))
    }
    public mutating func showSessions() { management.close(); drawer = false; menu = nil; confirmation = nil; page = 4 }
    private var host: HostMetrics?
    private var cpuHistory: [Double] = []
    private var width = 80
    private var height = 24
    private var page = 0
    private var cursor = 0
    private var history: [String] = []
    private var commandHistory: [String] = []
    private var chatHistory: [String] = []
    private var historyPosition: Int?
    private var draft = ""
    public private(set) var selectingText = false
    private var liveAnswer = ""
    private var liveReasoning = ""
    private var liveStatus = ""
    public mutating func progress(_ event: AIProgress) {
        switch event {
        case .answer(let text): liveAnswer = String((liveAnswer + text).suffix(24000))
        case .reasoning(let text): liveReasoning = String((liveReasoning + text).suffix(6000))
        case .status(let text):
            liveStatus = text
            if text.hasPrefix("Tool: ") { toolCount += 1 }
        case .snapshot(let text): liveAnswer = text; liveReasoning = ""
        }
    }
    public var chatVisible: Bool { aiMode && drawer }
    private var messages: [(String, String)] = []
    private var started = Date()
    private var animation = 0
    private var toolCount = 0
    public mutating func tick() { if busy { animation = (animation + 1) % 4 } }
    private var aiMode = false
    private var commandInChat = false
    private var transcript: [String] = ["Command drawer ready. Type help, or use Tab to complete."]
    private var scroll = 0
    private var menu: Int? = nil
    private var confirmation: String? = nil
    private var notice = "Select a service and press Enter to manage it."
    private let actions = ["Start", "Stop", "Restart", "Check health", "View logs", "Releases", "Rollback", "Back"]
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
    private enum Click { case key(TerminalKey), service(Int), session(Int), server(Int), action(Int), cursor(Int), workspace(Int), review(Int), newTask }
    private struct Hit { let row: Int; let column: Int; let width: Int; let click: Click }
    public mutating func finish(text: String, status: Int) {
        if commandInChat { messages.append((status == 0 ? "Kiln" : "Error", text)); messages = Array(messages.suffix(40)) }
        commandInChat = false
        liveAnswer = ""; liveReasoning = ""; liveStatus = ""
        busy = false; management.finish(text:text,status:status)
        let lines = text.components(separatedBy: "\n")
        transcript += lines
        transcript = Array(transcript.suffix(300)); scroll = 0
        notice = status == 0 ? (lines.count > 1 ? "Command completed. Output is in the drawer." : lines.first ?? "Done") : "Failed: " + (lines.first ?? "Unknown error")
    }
    private mutating func execute(_ command: String, display: String? = nil) -> [TerminalEffect] {
        guard !busy else { return [] }
        commandInChat = chatVisible
        busy = true; scroll = 0; transcript.append(display ?? ("> " + command))
        started = Date(); animation = 0; toolCount = 0
        liveAnswer = ""; liveReasoning = ""; liveStatus = ""
        if commandInChat { messages.append(("You", display.map { String($0.dropFirst(5)) } ?? command)) }
        notice = "Working: " + command
        return [.command(command)]
    }
    public mutating func handle(_ key: TerminalKey) -> [TerminalEffect] {
        if key == .selectText {
            selectingText.toggle()
            return [.selectText(selectingText)]
        }
        if selectingText { return [] }
        if management.active {
            if let command = management.handle(key,width:width,height:height) { return execute(command) }
            return []
        }
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
            case .server(let index): selectedServer = index; drawer = false; return handle(.enter)
            case .session(let index): selectedSession = index; drawer = false; return handle(.enter)
            case .action(let index): menu = index; return handle(.enter)
            case .workspace(let index): return chooseWorkspace(index)
            case .review(let action): return reviewAction(action)
            case .newTask:
                guard !busy else { return [] }
                reviewID = nil; sidebarFocus = false
                if !input.trimmingCharacters(in: .whitespaces).isEmpty { let prompt = input; input = ""; cursor = 0; return execute("ai task new " + Self.quote(prompt)) }
                input = "/task "; cursor = input.count; return []
            case .cursor(let offset): sidebarFocus = false; cursor = min(input.count, max(0, offset + column - hit.column)); return []
            }
        }
        if key == .text("`") || key == .text("~") {
            let wasCommandDrawer = drawer && !aiMode
            setAIChatMode(false)
            drawer = !wasCommandDrawer; menu = nil; confirmation = nil; return []
        }
        if chatVisible {
            if reviewID != nil {
                switch key {
                case .escape: reviewID = nil
                case .tab, .right, .down: reviewButton = (reviewButton + 1) % 3
                case .left, .up: reviewButton = (reviewButton + 2) % 3
                case .enter: return reviewAction(reviewButton)
                default: break
                }
                return []
            }
            if key == .tab { sidebarFocus.toggle(); return [] }
            if sidebarFocus {
                switch key {
                case .escape: sidebarFocus = false
                case .interrupt: sidebarFocus = false; return edit(key)
                case .up: sidebarSelected = max(0, sidebarSelected - 1)
                case .down: sidebarSelected = min(max(0, workspaceItems.count - 1), sidebarSelected + 1)
                case .enter: return chooseWorkspace(sidebarSelected)
                case .text("n"):
                    guard !busy else { return [] }; sidebarFocus = false; input = "/task "; cursor = input.count
                default: break
                }
                return []
            }
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
                case 5: menu = nil; drawer = true; return execute("app releases " + id)
                case 6: confirmation = "app rollback " + id
                default: menu = nil
                }
            default: break
            }
            return []
        }
        if page == 5 {
            switch key {
            case .text("n"): if !busy { management.newServer() }; return []
            case .up, .text("k"): selectedServer = max(0,selectedServer-1); return []
            case .down, .text("j"): selectedServer = min(max(0,servers.count-1),selectedServer+1); return []
            case .enter:
                if !busy, servers.indices.contains(selectedServer) { management.serverMenu(servers[selectedServer],row:9+min(selectedServer,max(0,height-12))) }; return []
            default: break
            }
        }
        if page == 4 {
            switch key {
            case .text("n"): if !busy { management.chooseServer() }; return []
            case .text("a"):
                guard sessions.indices.contains(selectedSession) else { return [] }
                return execute("session attach " + sessions[selectedSession].name)
            case .up, .text("k"): selectedSession = max(0, selectedSession - 1); return []
            case .down, .text("j"): selectedSession = min(max(0, sessions.count - 1), selectedSession + 1); return []
            case .enter:
                guard sessions.indices.contains(selectedSession) else { return [] }
                if !busy { management.sessionMenu(sessions[selectedSession].name,row:9+min(selectedSession,max(0,height-12))) }; return []
            default: break
            }
        }
        switch key {
        case .text("7"): openAIChat()
        case .text("6"): page = 5
        case .text("5"): page = 4
        case .text("1"): page = 0
        case .text("2"): page = 1
        case .text("3"): page = 2
        case .text("4"), .text("?"): page = 3
        case .tab: page = (page + 1) % 6
        case .up, .text("k"): selected = max(0, selected - 1)
        case .down, .text("j"): selected = min(max(0, modules.count - 1), selected + 1)
        case .enter: if page < 2 && !modules.isEmpty && !busy { menu = 0 }
        default: break
        }
        return []
    }
    private static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    private mutating func openAIChat() {
        guard !busy else { return }
        setAIChatMode(true)
        drawer = true; menu = nil; confirmation = nil
        input = ""; cursor = 0; historyPosition = nil; scroll = 0
    }
    private mutating func setAIChatMode(_ enabled: Bool) {
        guard aiMode != enabled else { return }
        if aiMode { chatHistory = history; history = commandHistory }
        else { commandHistory = history; history = chatHistory }
        aiMode = enabled
        input = ""; cursor = 0; historyPosition = nil; draft = ""
        sidebarFocus = false; reviewID = nil; scroll = 0
    }
    private mutating func edit(_ key: TerminalKey) -> [TerminalEffect] {
        var characters = Array(input)
        switch key {
        case .selectText: break
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
            let fixed = ["ai", "ai help", "ai status", "ai ask ", "ai reset", "vault help", "vault put ", "vault list", "vault grant ", "vault revoke ", "vault grants ", "vault delete ", "session help", "session list", "session open ", "session rename ", "session new ", "session attach ", "session close ", "help", "status", "metrics", "app list", "app install ", "app deploy ", "app rollback ", "app releases ", "app start ", "app stop ", "app restart ", "app health ", "app logs ", "server help", "server list", "server edit ", "server generate-key ", "server add ", "server scan ", "server trust ", "server key ", "server exec ", "server config ", "server remove ", "key create ", "key list", "key public ", "key delete ", "exit"]
            let sessionCommands = sessions.flatMap { ["session attach " + $0.name, "session close " + $0.name] }
            let expanded = ["start", "stop", "restart", "health", "logs", "rollback", "releases"].flatMap { operation in modules.map { "app \(operation) \($0.id)" } }
            let matches = (fixed + expanded + sessionCommands).filter { $0.hasPrefix(input) && $0 != input }
            if matches.count == 1 { input = matches[0]; cursor = input.count }
            else if !matches.isEmpty {
                var common = matches[0]
                for candidate in matches.dropFirst() { while !candidate.hasPrefix(common) { common.removeLast() } }
                if common.count > input.count { input = common; cursor = input.count }
                else { transcript += matches; transcript = Array(transcript.suffix(300)) }
            }
        case .pageUp: scroll = min(max(0, (aiMode ? chatBody(columns: max(1, width - (width >= 110 ? min(42, width / 3) + 3 : 2) - 3)).count : transcript.count) - 1), scroll + 5)
        case .pageDown: scroll = max(0, scroll - 5)
        case .mouse: break
        case .enter:
            guard !busy else { return [] }
            let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { return [] }
            if history.last != command { history.append(command); history = Array(history.suffix(100)) }
            input = ""; cursor = 0; historyPosition = nil
            if !aiMode && command == "ai" {
                openAIChat(); return []
            }
            if aiMode {
                if command == "/exit" { setAIChatMode(false); transcript.append("Left AI chat."); return [] }
                if command.hasPrefix("/recover ") { return execute("ai recovery new " + Self.quote(String(command.dropFirst(9)))) }
                if command == "/tasks" { return execute("ai task list") }
                if command.hasPrefix("/task ") { return execute("ai task new " + Self.quote(String(command.dropFirst(6)))) }
                if command.hasPrefix("/watch ") { return execute("ai task watch " + Self.quote(String(command.dropFirst(7)))) }
                if command.hasPrefix("/cancel ") { return execute("ai task cancel " + Self.quote(String(command.dropFirst(8)))) }
                if command == "/reset" { messages = []; transcript = []; return execute("ai reset") }
                if command.hasPrefix("/approve ") || command.hasPrefix("/deny ") { return execute("ai " + command.dropFirst()) }
                let quoted = "\"" + command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
                return execute("ai ask " + quoted, display: "You: " + command)
            }
            return execute(command)
        }
        return []
    }

    // Values from logs/errors are untrusted terminal content. Only printable ASCII
    // is emitted in cells; this also guarantees deterministic single-column widths.
    public static func safe(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar -> Character in
            let replacements: [UInt32: Character] = [0x2014: "-", 0x2013: "-", 0x2018: "'", 0x2019: "'", 0x201C: "\"", 0x201D: "\"", 0x2022: "*", 0x00A0: " "]
            if let replacement = replacements[scalar.value] { return replacement }
            if scalar.value >= 32 && scalar.value <= 126 { return Character(String(scalar)) }
            return scalar.value == 9 ? " " : "?"
        })
    }
    // Format only sanitized text: model output can never introduce terminal controls.
    private func chatText(_ text: String, columns: Int) -> [String] {
        var result: [String] = []
        for source in text.components(separatedBy: "\n") {
            var line = Self.safe(source).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if line.hasPrefix("#") { line = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("|") {
                let cells = line.split(separator: "|", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }
                line = cells.joined(separator: "  /  ")
            }
            while line.count > columns {
                let prefix = String(line.prefix(columns))
                let cut = prefix.lastIndex(of: " ").map { prefix.distance(from: prefix.startIndex, to: $0) }.flatMap { $0 > columns / 2 ? $0 : nil } ?? columns
                result.append(String(line.prefix(cut)))
                line = String(line.dropFirst(cut)); if line.first == " " { line.removeFirst() }
            }
            result.append(line)
        }
        return result
    }
    private func chatBody(columns: Int) -> [String] {
        var body: [String] = []
        for (role, text) in messages {
            body += [role.uppercased()] + chatText(text, columns: columns) + [""]
        }
        if busy {
            body += ["KILN"]
            if !liveAnswer.isEmpty { body += chatText(liveAnswer, columns: columns) }
            else if !liveReasoning.isEmpty { body += ["Provider reasoning"] + Array(chatText(liveReasoning, columns: columns).suffix(3)) }
            else { body += ["Waiting for provider..."] }
        }
        if body.isEmpty { body = ["What would you like to do?", "", "Inspect your services, investigate a problem, or create a task.", "", "Try: Show me what is running and check its health.", "", "Read tools run automatically. Changes require your approval.", "Prompts and tool results go to the selected provider; keep credentials in Vault."] }
        return body
    }
    private func chatLayout() -> (String, [Hit]) {
        let panelWidth = width >= 110 ? min(42, width / 3) : 0
        let panelOnly = panelWidth == 0 && sidebarFocus && reviewID == nil
        let left = panelWidth > 0 ? panelWidth + 3 : 2
        let columns = width - left - 3
        var hits: [Hit] = []
        let items = workspaceItems
        var panel = Array(repeating: "", count: height)
        panel[0] = "TASKS & APPROVALS" + (sidebarFocus ? " *" : "")
        panel[1] = "Tab focus / arrows / Enter"
        panel[2] = String(repeating: "-", count: max(1, (panelOnly ? width - 4 : panelWidth) - 2))
        panel[3] = "[ + New task from message ]"
        panel[5] = "\(aiWorkspace.proposals.count) approvals / \(aiWorkspace.tasks.count) tasks"
        let slots = max(1, (height - 9) / 3)
        let start = max(0, min(sidebarSelected - slots + 1, max(0, items.count - slots)))
        for (offset, item) in items.dropFirst(start).prefix(slots).enumerated() {
            let index = start + offset, row = 7 + offset * 3
            panel[row] = (index == sidebarSelected ? "> " : "  ") + item.title
            panel[row + 1] = "  " + item.subtitle
            if panelWidth > 0 || panelOnly {
                for line in row...row+1 { hits.append(Hit(row: line + 1, column: 2, width: panelOnly ? width - 4 : panelWidth - 1, click: .workspace(index))) }
            }
        }
        if items.isEmpty { panel[7] = aiWorkspace.error ?? "No pending work" }
        panel[height - 2] = "\(items.isEmpty ? 0 : sidebarSelected + 1)/\(items.count)  n: new task"
        panel[height - 1] = aiWorkspace.provider.map { "AI: " + $0.displayName + " | " + $0.billingLabel } ?? "AI: not configured"
        if panelWidth > 0 || panelOnly { hits.append(Hit(row: 4, column: 2, width: panelOnly ? width - 4 : panelWidth - 1, click: .newTask)) }
        if panelOnly {
            let rows = panel.map { "  " + String(Self.safe($0).prefix(width - 5)).padding(toLength: width - 3, withPad: " ", startingAt: 0) }
            return ("\u{1b}[?25l\u{1b}[H\u{1b}[0m" + rows.joined(separator: "\r\n"), hits)
        }
        var rowIndex = 0
        let accent = "\u{1b}[38;5;215m", muted = "\u{1b}[38;5;245m", normal = "\u{1b}[38;5;252m"
        func row(_ value: String = "", _ color: String = "") -> String {
            let sidebar = panelWidth > 0 ? " " + String(Self.safe(panel[min(rowIndex, height - 1)]).prefix(panelWidth - 2)).padding(toLength: panelWidth - 1, withPad: " ", startingAt: 0) + " | " : "  "
            rowIndex += 1
            let text = String((sidebar + Self.safe(value)).prefix(width - 1))
            return "\u{1b}[0m\u{1b}[48;5;234m" + (color.isEmpty ? normal : color) + text.padding(toLength: width - 1, withPad: " ", startingAt: 0) + "\u{1b}[0m"
        }
        let state = selectingText ? "[SELECT TEXT]" : busy ? "[streaming]" : "[ready]"
        var lines = [row("KILN AI CHAT / selected: " + (aiWorkspace.provider?.displayName ?? "not configured") + " " + state, accent), row(aiWorkspace.provider.map { $0.billingLabel + " / " + $0.label } ?? "AI: not configured", muted), row(String(repeating: "-", count: columns), muted), row(aiWorkspace.provider.map { "Model: " + $0.model } ?? "")]
        if let id = reviewID {
            let proposal = aiWorkspace.proposals.first { $0.id == id }
            let valid = proposal.map { $0.expires > Date() } ?? false
            var detail = ["REVIEW OPERATION", ""]
            if let proposal {
                detail += chatText("app " + proposal.operation + " " + proposal.module, columns: columns)
                detail += ["", "Approval: " + proposal.id, "Expires in \(max(0, Int(proposal.expires.timeIntervalSinceNow))) seconds", "", "Approving executes this exact operation.", "Restarts/stops can interrupt application traffic."]
            } else { detail += ["This approval is no longer available."] }
            for text in detail.prefix(max(0, height - 9)) { lines.append(row(text)) }
            while lines.count < height - 4 { lines.append(row()) }
            let buttons = [valid ? "Approve" : "Expired", valid ? "Deny" : "Unavailable", "Back"]
            for index in 0..<3 {
                let label = (reviewButton == index ? "> " : "  ") + "[ " + buttons[index] + " ]"
                hits.append(Hit(row: lines.count + 1, column: left + 1, width: label.count, click: .review(index)))
                lines.append(row(label, accent))
            }
            lines.append(row("Tab / arrows select    Enter activate    Esc back", muted))
            return ("\u{1b}[?25l\u{1b}[H" + lines.joined(separator: "\r\n"), hits)
        }
        let body = chatBody(columns: columns), capacity = height - 9
        let end = max(0, body.count - scroll)
        for text in body.prefix(end).suffix(capacity) {
            lines.append(row(text, ["YOU", "KILN", "ERROR"].contains(text) ? accent : normal))
        }
        while lines.count < height - 5 { lines.append(row()) }
        let backingOff = liveStatus.hasPrefix("Provider busy;")
        let phase = backingOff ? liveStatus : !liveAnswer.isEmpty ? "Receiving response" : !liveReasoning.isEmpty ? "Reasoning" : !liveStatus.isEmpty ? liveStatus : toolCount > 0 ? "Inspecting system" : "Waiting for provider"
        let spinner = ["|", "/", "-", "\\"][animation]
        let activity = busy ? "\(spinner) \(phase)  \(Int(Date().timeIntervalSince(started)))s  /  \(toolCount) tool calls" : "Ready" + (toolCount > 0 ? "  /  \(toolCount) tool calls" : "")
        lines += [row(selectingText ? "SELECT TEXT: drag to copy; Ctrl-S resumes" : activity, muted), row(String(repeating: "-", count: columns), accent)]
        let room = columns - 3, offset = max(0, cursor - room + 1)
        lines.append(row("> " + String(input.dropFirst(offset).prefix(room)), accent))
        lines.append(row("Enter send   Ctrl-C stop   Ctrl-S select/copy   PgUp/PgDn", muted))
        lines.append(row(scroll > 0 ? "Scrolled up / PgDn to return to live output" : "Esc dashboard | Tab tasks | /reset | /task", muted))
        return ("\u{1b}[?25l\u{1b}[H" + lines.joined(separator: "\r\n") + "\u{1b}[\(height-2);\(left+3+cursor-offset)H\u{1b}[?25h", hits + [Hit(row: height-2, column: left+3, width: room, click: .cursor(offset))])
    }

    public func render() -> String { layout().0 }
    private func layout() -> (String, [Hit]) {
        if chatVisible && width >= 50 && height >= 16 { return chatLayout() }
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
                     row("  LOCAL NODE  /  ONLINE  /  " + (accessLabel ?? "SSH SESSION"), green),
                     row(aiWorkspace.provider.map { "  Selected AI: " + $0.displayName + " | " + $0.billingLabel + " | " + $0.model } ?? "  Selected AI: not configured", accent)]
        let labels = width < 65 ? ["1", "2", "3", "4", "5", "6", "7 AI"] : width < 100 ? ["1 Home", "2 Apps", "3 CPU", "4 ?", "5 TTY", "6 SSH", "7 AI"] : ["1 Overview", "2 Services", "3 Metrics", "4 Help", "5 Sessions", "6 Servers", "7 AI Chat"]
        var tabs = "  "
        for (index,label) in labels.enumerated() {
            let text = (index == 6 ? aiMode && drawer : page == index && !(aiMode && drawer)) ? "[" + label + "]" : " " + label + " "
            hits.append(Hit(row: 4, column: tabs.count+1, width: text.count, click: .key(.text(String(index+1)))))
            tabs += text + " "
        }
        lines.append(row(tabs, accent))
        lines.append(row("  " + String(repeating: "-", count: max(0,w-4)), muted))
        let bodyEnd = drawer ? (aiMode ? 8 : max(8, height / 2)) : height - 3
        if aiMode && drawer {
            lines.append(row("  NATIVE SWIFT AI  /  LIVE KILN TOOLS", accent))
            lines.append(row("  Read tools automatic; changes need your explicit approval.", muted))
        } else if page == 5 {
            lines.append(row("  SERVERS   [n Add server]",accent))
            hits.append(Hit(row:6,column:13,width:14,click:.key(.text("n"))))
            lines.append(row("  Enter/click manage | key setup | verify identity | new terminal",muted))
            lines.append(row("  " + fit("NAME",max(10,w/4)) + fit("DESTINATION",max(12,w/3)) + "KEY / TRUST",muted))
            let capacity = max(1,bodyEnd-lines.count), offset = max(0,selectedServer-max(1,bodyEnd-lines.count)+1)
            for index in offset..<min(servers.count,offset+capacity) {
                let server = servers[index]
                hits.append(Hit(row:lines.count+1,column:1,width:w,click:.server(index)))
                lines.append(row((index == selectedServer ? "> " : "  ") + fit(server.name,max(10,w/4)) + fit(server.host+":"+String(server.port),max(12,w/3)) + (server.key ?? "no key") + (server.fingerprint == nil ? " / unverified" : " / pinned"),fg,selected:index == selectedServer))
            }
            if servers.isEmpty { lines.append(row("  No servers yet. Press n or click Add server.",muted)) }
        } else if page == 4 {
            lines.append(row("  TERMINAL SESSIONS   [n New terminal]", accent))
            hits.append(Hit(row:6,column:23,width:16,click:.key(.text("n"))))
            lines.append(row("  Enter/click actions | a attach | n new terminal", muted))
            lines.append(row("  " + fit("NAME", max(10,w/3)) + fit("SERVER", max(8,w/4)) + "STATE / VIEWER", muted))
            let capacity = max(1, bodyEnd - lines.count)
            let offset = max(0, selectedSession - capacity + 1)
            for index in offset..<min(sessions.count, offset + capacity) {
                let session = sessions[index]
                hits.append(Hit(row: lines.count+1, column: 1, width: w, click: .session(index)))
                lines.append(row((index == selectedSession ? "> " : "  ") + fit(session.name,max(10,w/3)) + fit(session.server,max(8,w/4)) + session.state + (session.attached ? " / attached" : " / detached"), fg, selected: index == selectedSession))
            }
            if sessions.isEmpty { lines.append(row("  No sessions yet. Press n or click New terminal.", muted)) }
        } else if page == 3 {
            for text in ["  Click tabs, services, actions or the drawer bar.", "  Mouse wheel scrolls output or service selection.", "  Navigate", "  Up / Down or j / k    Select a service", "  Enter                 Open its action menu", "  Tab or 1 / 2 / 3 / 4 / 5 / 6  Switch views", "  ` or ~                Toggle command drawer", "  Esc                   Close drawer or menu", "  q                     Disconnect", "", "  Command drawer", "  Up / Down             Command history", "  Tab                   Complete commands and service IDs", "  Left / Right          Edit the command", "  Ctrl-A / E            Beginning / end of line", "  PgUp / PgDn           Scroll command output", "", "  Process state is not a health check."] {
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
            lines.append(row("  \(aiMode ? "KILN AI CHAT" : "COMMAND DRAWER")   \(selectingText ? "[SELECT TEXT · Ctrl-S resumes]" : busy ? (aiMode ? "[streaming]" : "[working]") : "[ready]")   Esc / ` to close", accent))
            let available = max(0, height - lines.count - 3)
            let liveLines = (liveStatus.isEmpty ? [] : ["Activity: " + liveStatus]) +
                (liveReasoning.isEmpty ? [] : ["Provider reasoning: " + liveReasoning]) +
                (liveAnswer.isEmpty ? [] : ["Assistant: " + liveAnswer])
            let displayLines: [String] = aiMode ? (transcript + liveLines).flatMap { text -> [String] in
                var rest = Self.safe(text); var wrapped: [String] = []
                let columns = max(1, w - 3)
                while rest.count > columns {
                    let prefix = String(rest.prefix(columns))
                    let cut = prefix.lastIndex(of: " ").map { prefix.distance(from: prefix.startIndex, to: $0) }.flatMap { $0 > columns / 2 ? $0 : nil } ?? columns
                    wrapped.append(String(rest.prefix(cut))); rest = String(rest.dropFirst(cut))
                    if rest.first == " " { rest.removeFirst() }
                }
                wrapped.append(rest); return wrapped
            } : transcript
            let end = max(0, displayLines.count - scroll)
            let visible = Array(displayLines.prefix(end).suffix(available))
            for text in visible { lines.append(row("  " + text, text.hasPrefix("Error") ? red : fg)) }
            while lines.count < height - 3 { lines.append(row()) }
            let room = max(1,w-9)
            let offset = max(0, cursor - room + 1)
            let shown = String(Array(input).dropFirst(offset).prefix(room))
            hits.append(Hit(row: height-2, column: 10, width: room, click: .cursor(offset)))
            lines.append(row((aiMode ? "  chat > " : "  kiln > ") + shown, accent))
            lines.append(row(aiMode ? "  Ctrl-S select/copy | /task | /tasks | /exit | PgUp/PgDn" : "  Tab complete  |  Up/Down history  |  PgUp/PgDn output", muted))
            lines.append(row("  " + (selectingText ? "SELECT TEXT: drag to select and copy; Ctrl-S resumes." : notice), muted))
            let cursorColumn = min(w, 10 + cursor - offset)
            return ("\u{1b}[?25l\u{1b}[H" + lines.prefix(height).joined(separator: "\r\n") + "\u{1b}[\(height-2);\(cursorColumn)H\u{1b}[?25h", hits)
        }
        lines.append(row("  " + (selectingText ? "SELECT TEXT: drag to select and copy; Ctrl-S resumes." : notice), muted))
        lines.append(row(page == 4 ? "  Enter actions | a attach | n new | ` drawer | q exit" : "  Click/Enter manage | 7 AI | ` drawer | ? help | q exit", accent))
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
        return ("\u{1b}[?25l\u{1b}[H" + lines.prefix(height).joined(separator: "\r\n") + overlay + management.render(width:width,height:height), hits)
    }
}
