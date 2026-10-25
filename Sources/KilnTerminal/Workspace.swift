import Foundation
import KilnKit

/// File tree and editor share the same registered-project commands as the AI.
struct WorkspaceUI {
    let module: String
    let change: String?
    var active = true
    private struct Entry: Decodable { let path: String; let sha256: String; let bytes: Int }
    private struct Tree: Decodable { let version: String; let editable: Bool; let projectRoot: Bool; let files: [Entry] }
    private struct File: Decodable { let file: String; let sha256: String; let source: String; let version: String }
    private struct Browse: Decodable { let tree: Tree; let file: File }
    private var entries: [Entry] = []
    private var selected = 0
    private var path = "App.swift", hash = "", source = "", version = ""
    private var editable = false, projectRoot = false, treeFocus = true, waiting = true
    private var mode = "browse", pending = "browse", error = "", receipt = "", newPath = "", draft = "", isNew = false
    private var confirmation = "", accepted = false
    private var offset = 0, horizontal = 0, cursor = 0
    init(module: String, change: String? = nil) { self.module = module; self.change = change }
    private func command(_ parts: [String]) -> String { parts.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ") }
    func load() -> String { command(["web", "browse", module, "App.swift"] + (change.map { [$0] } ?? [])) }
    private mutating func request(_ name: String, _ parts: [String]) -> String { waiting = true; pending = name; error = ""; return command(parts) }
    mutating func finish(text: String, status: Int) {
        waiting = false
        if pending == "apply" { mode = "receipt"; receipt = text; error = status == 0 ? "" : "Change failed or unconfirmed. Inspect history and release before another write."; return }
        guard status == 0, let data = text.data(using: .utf8) else { error = text; return }
        do {
            let file: File
            if pending == "browse" {
                let view = try JSONDecoder().decode(Browse.self, from: data)
                entries = view.tree.files; editable = view.tree.editable; projectRoot = view.tree.projectRoot; file = view.file
            } else { file = try JSONDecoder().decode(File.self, from: data) }
            path = file.file; hash = file.sha256; source = file.source; version = file.version
            selected = entries.firstIndex(where: { $0.path == path }) ?? 0
            mode = "browse"; offset = 0; horizontal = 0
        } catch { self.error = "Invalid project browser response" }
    }
    private mutating func publish(delete: Bool = false) -> String? {
        let operation: [String:String]
        if delete { operation = ["path":path,"action":"delete","sha256":hash] }
        else if isNew { operation = ["path":path,"action":"create","content":draft] }
        else { operation = ["path":path,"action":"replace","sha256":hash,"content":draft] }
        guard let data = try? JSONEncoder().encode([operation]), let json = String(data:data,encoding:.utf8) else { return nil }
        return request("apply",["web","apply",module,json])
    }
    mutating func handle(_ key: TerminalKey, width: Int, height: Int) -> String? {
        guard !waiting else { return nil }
        if mode == "receipt" {
            if key == .enter { return request("browse", ["web","browse",module,"App.swift"] + (change.map { [$0] } ?? [])) }
            if key == .escape { active = false }
            if key == .pageDown { offset += max(1,height-8) }
            if key == .pageUp { offset = max(0,offset-max(1,height-8)) }
            return nil
        }
        if !confirmation.isEmpty {
            if key == .escape { confirmation = ""; return nil }
            if key == .up || key == .down || key == .tab { accepted.toggle() }
            if key == .enter {
                let operation = confirmation; confirmation = ""
                guard accepted else { return nil }
                if operation == "discard" { mode = "browse"; draft = ""; offset = 0; if isNew { return request("browse",["web","browse",module,"App.swift"]) }; return nil }
                return publish(delete: operation == "delete")
            }
            return nil
        }
        if mode == "name" {
            if key == .escape { mode = "browse" }
            if key == .backspace, !newPath.isEmpty { newPath.removeLast() }
            if case .text(let text) = key, newPath.count + text.count <= 180 { newPath += text }
            if case .paste(let text) = key, newPath.count + text.count <= 180, !text.contains("\n") { newPath += text }
            if key == .enter {
                guard !newPath.isEmpty, !entries.contains(where: { $0.path == newPath }) else { error = "Choose a new relative file path"; return nil }
                path = newPath; draft = ""; cursor = 0; offset = 0; horizontal = 0; isNew = true; mode = "edit"; error = ""
            }
            return nil
        }
        if mode == "edit" {
            if key == .escape { confirmation = "discard"; accepted = false; return nil }
            if key == .eof { guard isNew || draft != source else { error = "No changes to publish"; return nil }; confirmation = "publish"; accepted = false; return nil }
            var chars = Array(draft); cursor = min(cursor,chars.count)
            let lineStart = chars[..<cursor].lastIndex(of:"\n").map { $0+1 } ?? 0
            let lineEnd = chars[cursor...].firstIndex(of:"\n") ?? chars.count
            switch key {
            case .text(let text), .paste(let text):
                let safe = String(text.unicodeScalars.filter { $0.value >= 32 || $0.value == 10 || $0.value == 9 })
                guard draft.utf8.count + safe.utf8.count <= 65536 else { error = "File limit is 64 KiB"; return nil }
                chars.insert(contentsOf: safe,at:cursor); cursor += safe.count
            case .enter: if draft.utf8.count < 65536 { chars.insert("\n",at:cursor); cursor += 1 }
            case .tab: if draft.utf8.count+4 <= 65536 { chars.insert(contentsOf:"    ",at:cursor); cursor += 4 }
            case .backspace: if cursor > 0 { chars.remove(at:cursor-1); cursor -= 1 }
            case .delete: if cursor < chars.count { chars.remove(at:cursor) }
            case .left: cursor = max(0,cursor-1)
            case .right: cursor = min(chars.count,cursor+1)
            case .home: cursor = lineStart
            case .end: cursor = lineEnd
            case .up:
                if lineStart > 0 { let end = lineStart-1, start = chars[..<end].lastIndex(of:"\n").map { $0+1 } ?? 0; cursor = min(end,start+cursor-lineStart) }
            case .down:
                if lineEnd < chars.count { let start = lineEnd+1, end = chars[start...].firstIndex(of:"\n") ?? chars.count; cursor = min(end,start+cursor-lineStart) }
            default: break
            }
            draft = String(chars)
            let before = Array(chars.prefix(cursor)), line = before.filter { $0 == "\n" }.count
            let visible = max(1,height-8)
            if line < offset { offset = line }; if line >= offset+visible { offset = line-visible+1 }
            let column = before.reversed().prefix(while: { $0 != "\n" }).count
            let room = max(8,(width-4)-min(32,max(18,(width-4)/4))-11)
            if column < horizontal { horizontal = column }; if column >= horizontal+room { horizontal = column-room+1 }
            return nil
        }
        if key == .text("w") || key == .text("W"), change != nil {
            self = WorkspaceUI(module: module)
            return load()
        }
        if key == .escape { active = false; return nil }
        if key == .tab { treeFocus.toggle() }
        if treeFocus, key == .up { selected = max(0,selected-1) }
        if treeFocus, key == .down { selected = min(max(0,entries.count-1),selected+1) }
        if treeFocus, key == .enter, entries.indices.contains(selected) { return request("file",["web","file",module,entries[selected].path] + (change.map { [$0] } ?? [])) }
        if !treeFocus, key == .up { offset = max(0,offset-1) }
        if !treeFocus, key == .down { offset += 1 }
        if !treeFocus, key == .left { horizontal = max(0,horizontal-8) }
        if !treeFocus, key == .right { horizontal += 8 }
        if key == .pageDown { offset += max(1,height-7) }
        if key == .pageUp { offset = max(0,offset-max(1,height-7)) }
        if key == .text("e") || key == .text("E") {
            guard editable else { error = "Retained versions are read-only. Open Codebase for workspace edits."; return nil }
            // Edit the file shown, not a different highlighted tree row.
            draft = source; isNew = false; mode = "edit"; cursor = 0; offset = 0; horizontal = 0; error = ""
        }
        if key == .text("a") || key == .text("A") {
            guard editable && projectRoot else { error = "Adding files needs an explicitly registered project root"; return nil }
            newPath = ""; mode = "name"; error = ""
        }
        if key == .text("x") || key == .text("X") {
            guard editable && projectRoot && path != "App.swift" else { error = "Only additional workspace files can be deleted"; return nil }
            confirmation = "delete"; accepted = false
        }
        return nil
    }
    private var treeRows: [(String,Int?)] {
        var rows: [(String,Int?)] = [], seen = Set<String>()
        for (index, entry) in entries.enumerated() {
            let parts = entry.path.split(separator:"/").map(String.init)
            for depth in 0..<max(0,parts.count-1) {
                let directory = parts.prefix(depth+1).joined(separator:"/")
                if seen.insert(directory).inserted { rows.append((String(repeating:"  ",count:depth)+"+ "+parts[depth]+"/",nil)) }
            }
            rows.append((String(repeating:"  ",count:parts.count-1)+parts.last!,index))
        }
        return rows
    }
    func render(width: Int, height: Int, theme: TerminalTheme) -> String {
        guard width >= 50, height >= 16 else { return "" }
        let w = width-4, h = height-2, left = 3, top = 2, treeWidth = min(32,max(18,w/4)), codeWidth = w-treeWidth-5
        let display = mode == "edit" ? draft : source
        let lines = display.components(separatedBy:"\n")
        let start = min(offset,max(0,lines.count-1))
        var lexer = SourceSyntax(), syntax: [[Int?]] = []
        for line in lines { syntax.append(lexer.colors(KilnTerminal.safe(line).replacingOccurrences(of:"\t",with:"    "),path:path)) }
        func fit(_ value: String, _ count: Int) -> String { String(KilnTerminal.safe(value).prefix(max(0,count))).padding(toLength:max(0,count),withPad:" ",startingAt:0) }
        var out = ""
        func row(_ y: Int, _ value: String) { out += "\u{1b}[\(top+y);\(left)H\u{1b}[0;48;5;\(theme.background);38;5;\(theme.foreground)m" + value + "\u{1b}[0m" }
        row(0,"+"+String(repeating:"-",count:w-2)+"+")
        row(1,"| "+fit("Codebase / \(module) / \(version)\(change == nil ? "" : " / read-only")",w-4)+" |")
        row(2,"| "+fit("FILES" + (treeFocus ? " [focus]" : ""),treeWidth)+"| "+fit(path + (mode == "edit" ? " [EDITING]" : ""),codeWidth)+"|")
        let nodes = treeRows
        let selectedRow = nodes.firstIndex(where: { $0.1 == selected }) ?? 0
        let listStart = max(0,selectedRow-max(1,h-8)+1)
        for y in 3..<h-3 {
            let n = y-3, index = start+n, treeIndex = listStart+n
            var label = ""
            if nodes.indices.contains(treeIndex) { label = (nodes[treeIndex].1 == selected ? "> " : "  ") + nodes[treeIndex].0 }
            let treeColor = nodes.indices.contains(treeIndex) && nodes[treeIndex].1 == selected ? theme.accent : theme.foreground
            var body = "| \u{1b}[38;5;\(treeColor)m"+fit(label,treeWidth)+"\u{1b}[38;5;\(theme.foreground)m| "
            if index < lines.count {
                let safe = KilnTerminal.safe(lines[index]).replacingOccurrences(of:"\t",with:"    ")
                let content = String(safe.dropFirst(horizontal).prefix(max(1,codeWidth-7)))
                body += "\u{1b}[38;5;244m"+String(format:"%5d ",index+1)+"\u{1b}[38;5;\(theme.foreground)m"+SourceSyntax.styled(fit(content,codeWidth-6),colors:Array(syntax[index].dropFirst(min(horizontal,syntax[index].count))),base:theme.foreground)+"|"
            } else { body += fit("",codeWidth)+"|" }
            row(y,body)
        }
        let footer = waiting ? "Working..." : !error.isEmpty ? error : mode == "edit" ? "Ctrl-D publish  Esc cancel  Arrows move" : (change == nil ? "Tab focus  Enter open  E edit  A add  X delete  PgUp/Dn  Esc back" : "Read-only revision  W workspace  Tab focus  Enter open  PgUp/Dn  Esc back")
        row(h-3,"| "+fit(footer,w-4)+" |")
        row(h-2,"| "+fit("Files stay inside the registered project; publish compiles and checks health.",w-4)+" |")
        row(h-1,"+"+String(repeating:"-",count:w-2)+"+")
        if mode == "name" { row(4,"| "+fit("New relative path (Enter to edit, Esc cancel): "+newPath,w-4)+" |") }
        if mode == "receipt" {
            let all = (error.isEmpty ? receipt : error+"\n"+receipt).components(separatedBy:"\n")
            for (i,line) in all.dropFirst(min(offset,max(0,all.count-1))).prefix(h-7).enumerated() { row(3+i,"| "+fit(line,w-4)+" |") }
            row(h-3,"| "+fit("Enter refresh files  Esc back  PgUp/PgDn scroll",w-4)+" |")
        }
        if !confirmation.isEmpty {
            let question = confirmation == "discard" ? "Discard unsaved edits?" : confirmation == "delete" ? "Delete \(path) and publish? History keeps this file." : "Compile and publish \(path)?"
            row(5,"| "+fit(question,w-4)+" |")
            row(6,"| "+fit(accepted ? "  Cancel     > Confirm" : "> Cancel       Confirm",w-4)+" |")
            row(7,"| "+fit("Up/Down choose  Enter  Esc cancel",w-4)+" |")
        } else if mode == "edit" {
            let before = String(draft.prefix(cursor)), y = before.filter { $0 == "\n" }.count-offset
            let column = KilnTerminal.safe(String(before.split(separator:"\n",omittingEmptySubsequences:false).last ?? "")).replacingOccurrences(of:"\t",with:"    ").count-horizontal
            if y >= 0, y < h-6, column >= 0, column < codeWidth-6 { out += "\u{1b}[\(top+3+y);\(left+treeWidth+10+column)H\u{1b}[?25h" }
        }
        return out
    }
}
