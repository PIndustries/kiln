import Foundation
import KilnKit

/// Menu/form state shared by mouse and keyboard paths. No secrets are accepted here.
struct ManagementUI {
    var servers: [ServerSnapshot] = []
    var keys: [String] = []
    var active = false
    private var kind = ""
    private var server: ServerSnapshot?
    private var session = ""
    private var title = ""
    private var help = ""
    private var options: [String] = []
    private var labels: [String] = []
    private var fields: [String] = []
    private var prefix: [String] = []
    private var selected = 0
    private var cursor = 0
    private var error = ""
    private var waiting = false
    private var message = ""
    private var pending = ""
    private var anchor = 9
    private var messageOffset = 0
    mutating func close() { active = false; waiting = false }
    mutating func menu(_ kind: String, title: String, options: [String], row: Int = 9) {
        self.kind = kind; self.title = title; self.options = options; anchor = row
        labels = []; fields = []; selected = 0; error = ""; message = ""; help = "Up/Down select | Enter choose | Esc back"
        active = true; waiting = false
    }
    mutating func form(title: String, labels: [String], values: [String], prefix: [String], help: String = "Tab next | Enter continue/save | Esc cancel") {
        kind = "form"; self.title = title; self.labels = labels; fields = values; self.prefix = prefix
        options = []; selected = 0; cursor = fields.first?.count ?? 0; error = ""; message = ""; self.help = help; active = true; waiting = false
    }
    mutating func newServer() { form(title:"Add server",labels:["Name","Host","User","Port"],values:["","","","22"],prefix:["server","add"]) }
    mutating func serverMenu(_ server: ServerSnapshot, row: Int) {
        self.server = server
        menu("server",title:server.name,options:["New terminal","Edit server","Assign existing key","Generate and assign key","Show public key","Scan host key","Verify host key","Remove server","Back"],row:row)
    }
    mutating func sessionMenu(_ name: String, row: Int) {
        session = name; menu("session",title:name,options:["Attach","Rename","Close session","Back"],row:row)
    }
    mutating func chooseServer() {
        menu("chooseServer",title:"New terminal - choose server",options:servers.map(\.name)+["Add server","Back"])
    }
    mutating func newTerminal(_ name: String) {
        form(title:"New terminal on " + name,labels:["Session name"],values:[""],prefix:["session","open"],help:"Enter a name. The terminal starts and attaches after save.")
        session = name
    }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of:"'",with:"'\\''") + "'" }
    private mutating func run(_ parts: [String]) -> String {
        waiting = true; pending = parts.prefix(2).joined(separator:" ")
        return parts.map(Self.quote).joined(separator:" ")
    }
    mutating func finish(text: String, status: Int) {
        guard waiting else { return }; waiting = false
        if status != 0 { error = text; return }
        if ["session open","session attach","session rename","session close","server add","server edit","server key","server remove","server trust"].contains(pending) { close(); return }
        kind = "message"; title = pending == "server scan" ? "Unverified host identity" : "Public key / result"
        message = text; messageOffset = 0; labels = []; options = ["Back"]; selected = 0; help = "PgUp/PgDn scroll | Enter / Esc close"
    }
    mutating func handle(_ key: TerminalKey, width: Int, height: Int) -> String? {
        if key == .escape || key == .interrupt { if !waiting { close() }; return nil }
        guard !waiting else { return nil }
        if case let .mouse(button,column,row,released) = key {
            guard !released, button == 0 else { return nil }
            let geometry = geometry(width:width,height:height)
            guard column >= geometry.left, column < geometry.left+geometry.width else { return nil }
            let index = row - geometry.top - 2
            if kind == "message" { close(); return nil }
            if kind != "form", options.indices.contains(index) { selected = index; return handle(.enter,width:width,height:height) }
            if kind == "form" {
                if fields.indices.contains(index) { selected = index; cursor = fields[index].count }
                else if index == fields.count+1 {
                    selected = fields.count + (column >= geometry.left+18 ? 1 : 0)
                    return handle(.enter,width:width,height:height)
                }
            }
            return nil
        }
        if kind == "message" {
            if key == .enter { close() }
            if key == .pageDown { messageOffset += 4 }
            if key == .pageUp { messageOffset = max(0,messageOffset-4) }
            return nil
        }
        let count = kind == "form" ? fields.count+2 : options.count
        switch key {
        case .tab, .down: selected = (selected+1) % max(1,count); cursor = fields.indices.contains(selected) ? fields[selected].count : 0
        case .up: selected = (selected+count-1) % max(1,count); cursor = fields.indices.contains(selected) ? fields[selected].count : 0
        case .enter:
            if kind == "form" {
                if selected == fields.count+1 { close(); return nil }
                if selected < fields.count-1 { selected += 1; cursor = fields[selected].count; return nil }
                if fields.contains(where:{$0.isEmpty}) { error = "Fill every field before saving."; return nil }
                return run(prefix + fields + (prefix == ["session","open"] ? [session] : []))
            }
            return choose()
        default:
            guard kind == "form", fields.indices.contains(selected) else { return nil }
            var characters = Array(fields[selected]); cursor = min(cursor,characters.count)
            switch key {
            case .text(let text), .paste(let text):
                let safe = String(text.unicodeScalars.filter { $0.value >= 32 && $0.value < 127 })
                guard characters.count+safe.count <= 512 else { return nil }
                characters.insert(contentsOf:Array(safe),at:cursor); cursor += safe.count
            case .backspace: if cursor > 0 { characters.remove(at:cursor-1); cursor -= 1 }
            case .delete: if cursor < characters.count { characters.remove(at:cursor) }
            case .left: cursor = max(0,cursor-1)
            case .right: cursor = min(characters.count,cursor+1)
            case .home: cursor = 0
            case .end: cursor = characters.count
            case .clearBefore: characters.removeFirst(cursor); cursor = 0
            case .clearAfter: characters = Array(characters.prefix(cursor))
            default: break
            }
            fields[selected] = String(characters)
        }
        return nil
    }
    private mutating func choose() -> String? {
        guard options.indices.contains(selected) else { return nil }
        let choice = options[selected]
        if choice == "Back" || choice == "Cancel" { close(); return nil }
        switch kind {
        case "server":
            guard let server else { return nil }
            switch choice {
            case "New terminal": newTerminal(server.name)
            case "Edit server": form(title:"Edit " + server.name,labels:["Host","User","Port"],values:[server.host,server.user,String(server.port)],prefix:["server","edit",server.name],help:"Changing host/port clears its host-key trust. Existing sessions stay connected.")
            case "Assign existing key": menu("chooseKey",title:"Assign key to " + server.name,options:keys+["Back"])
            case "Generate and assign key": form(title:"Generate Ed25519 key",labels:["Key name"],values:[""],prefix:["server","generate-key",server.name])
            case "Show public key":
                guard let key = server.key else { error = "Assign or generate a key first."; return nil }; return run(["key","public",key])
            case "Scan host key": return run(["server","scan",server.name])
            case "Verify host key":
                guard let candidate = server.candidate else { error = "Scan the host key first."; return nil }
                form(title:"Verify " + server.name,labels:["Verified SHA256"],values:[""],prefix:["server","trust",server.name],help:"Compare independently, then enter fingerprint: " + candidate)
            case "Remove server": confirm("Remove " + server.name + "?",command:["server","remove",server.name],detail:"Blocks new connections; existing sessions remain connected.")
            default: break
            }
        case "chooseServer":
            if choice == "Add server" { newServer() } else { newTerminal(choice) }
        case "chooseKey": if let server { return run(["server","key",server.name,choice]) }
        case "session":
            switch choice {
            case "Attach": return run(["session","attach",session])
            case "Rename": form(title:"Rename " + session,labels:["New name"],values:[session],prefix:["session","rename",session])
            case "Close session": confirm("Close " + session + "?",command:["session","close",session],detail:"Ends the remote shell. Unsaved work may be lost.")
            default: break
            }
        case "confirm": return run(prefix)
        default: break
        }
        return nil
    }
    private mutating func confirm(_ title:String,command:[String],detail:String) {
        menu("confirm",title:title,options:["Cancel","Confirm"]); prefix = command; help = detail
    }
    private func geometry(width:Int,height:Int) -> (left:Int,top:Int,width:Int,height:Int) {
        let w = max(20,min(width-4,kind == "form" || kind == "message" ? 84 : max(36,title.count+6)))
        let desired = kind == "form" ? labels.count+9 : kind == "message" ? min(20,height-2) : options.count+(kind == "confirm" ? 8 : 6)
        let h = min(height-2,desired)
        let left = ["server","session"].contains(kind) ? min(title.count+4,width-w-1) : (width-w)/2
        return (max(1,left), max(1,min(anchor,height-h)),w,h)
    }
    func render(width:Int,height:Int,theme:TerminalTheme = TerminalTheme()) -> String {
        guard active, width >= 50, height >= 16 else { return "" }
        let g = geometry(width:width,height:height), room = g.width-4
        func fit(_ text:String) -> String { String(KilnTerminal.safe(text).prefix(room)).padding(toLength:room,withPad:" ",startingAt:0) }
        func wrap(_ text:String) -> [String] {
            var remaining = text, lines: [String] = []
            while !remaining.isEmpty {
                let prefix = String(remaining.prefix(room))
                let count = remaining.count > room ? (prefix.lastIndex(of:" ").map { prefix.distance(from:prefix.startIndex,to:$0) }.flatMap { $0 > 0 ? $0 : nil } ?? room) : remaining.count
                lines.append(String(remaining.prefix(count))); remaining = String(remaining.dropFirst(count)).trimmingCharacters(in:.whitespaces)
            }
            return lines
        }
        var rows = [(title,true)]
        if kind == "form" {
            for i in labels.indices {
                let available = max(1,room-labels[i].count-2)
                let offset = selected == i ? max(0,cursor-available+1) : 0
                rows.append((labels[i] + ": " + String(fields[i].dropFirst(offset).prefix(available)),selected == i))
            }
            rows.append(("",false)); rows.append(((selected == fields.count ? "> " : "  ") + "[Save]" + "        " + (selected == fields.count+1 ? "> " : "  ") + "[Cancel]", selected >= fields.count))
            rows += wrap(help).map { ($0,false) }
        } else if kind == "message" {
            var wrapped: [String] = []
            for line in message.components(separatedBy:"\n") {
                var remaining = KilnTerminal.safe(line)
                repeat { wrapped.append(String(remaining.prefix(room))); remaining = String(remaining.dropFirst(room)) } while !remaining.isEmpty
            }
            rows += wrapped.dropFirst(min(messageOffset,max(0,wrapped.count-1))).prefix(g.height-5).map { ($0,false) }
        } else { rows += options.enumerated().map { ((selected == $0.offset ? "> " : "  ") + $0.element,selected == $0.offset) } }
        if kind == "confirm" {
            rows.append(("",false)); rows += wrap(help).map { ($0,false) }
        }
        let border = "+" + String(repeating:"-",count:g.width-2) + "+"
        var output = ""
        for index in 0..<g.height {
            let text: String, highlighted: Bool
            if index == 0 || index == g.height-1 { text = border; highlighted = false }
            else if index == g.height-2 { text = "| " + fit(waiting ? "Working..." : error.isEmpty ? (kind == "confirm" ? "Enter choose | Esc cancel" : help) : error) + " |"; highlighted = false }
            else if index-1 < rows.count { text = "| " + fit(rows[index-1].0) + " |"; highlighted = rows[index-1].1 }
            else { text = "| " + fit("") + " |"; highlighted = false }
            output += "\u{1b}[\(g.top+index);\(g.left)H\u{1b}[0;48;5;\(highlighted ? 238 : theme.background);38;5;\(highlighted ? theme.accent : theme.foreground)m" + text + "\u{1b}[0m"
        }
        if kind == "form", fields.indices.contains(selected), !waiting {
            let offset = max(0,cursor-max(1,room-labels[selected].count-2)+1)
            let x = min(g.left+g.width-3,g.left+2+labels[selected].count+2+cursor-offset)
            output += "\u{1b}[\(g.top+2+selected);\(x)H\u{1b}[?25h"
        }
        return output
    }
}
