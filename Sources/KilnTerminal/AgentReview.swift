import Foundation
import KilnKit

/// Read-only proposal review. Staging is a separate explicit local-draft action.
struct AgentReviewUI {
    let module: String
    var active = true
    private(set) var waiting = true
    private var pending = "list"
    private var rows: [AgentProposalSummary] = []
    private var selected = 0
    private var view: AgentFileReview?
    private var tab = 0, offset = 0, horizontal = 0
    private var error = ""
    private var confirm = false
    var fileContext: (String,String,Int,String)? { view.map { ($0.path,$0.currentSHA256,offset+1,$0.worker) } }
    enum Action { case read([String]), stage([String]) }
    mutating func finish(_ text: String, status: Int) {
        waiting = false
        guard status == 0 else { error = text; return }
        do {
            if pending == "list" {
                if text == "No retained agent proposals" { rows = [] }
                else { rows = try JSONDecoder().decode([AgentProposalSummary].self,from:Data(text.utf8)).reversed() }
                selected = min(selected,max(0,rows.count-1)); view = nil
            } else { view = try JSONDecoder().decode(AgentFileReview.self,from:Data(text.utf8)); offset = 0; horizontal = 0 }
            error = ""
        } catch { self.error = "Invalid agent review response" }
    }
    mutating func failedStage(_ text: String) { waiting = false; confirm = false; error = text }
    private mutating func read(_ parts: [String], kind: String) -> Action {
        waiting = true; pending = kind; error = ""; return .read(parts)
    }
    mutating func handle(_ key: TerminalKey, width: Int, height: Int) -> Action? {
        guard !waiting else { return nil }
        if key == .escape || key == .agentReview {
            if confirm { confirm = false }
            else if view != nil { view = nil; offset = 0; horizontal = 0 }
            else { active = false }
            return nil
        }
        if confirm {
            guard key == .enter, let file = view else { return nil }
            waiting = true
            return .stage(["web","agent-stage",module,file.worker,file.path,file.currentSHA256,file.proposalSHA256])
        }
        if let file = view {
            if key == .tab { tab = (tab+1)%4; offset = 0; horizontal = 0 }
            if key == .text("s") || key == .text("S") { confirm = true; return nil }
            if key == .text("r") || key == .text("R") { return read(["web","agent-review",module,file.worker,file.path],kind:"file") }
            let index = file.files.firstIndex(of:file.path) ?? 0
            if key == .text("[") || key == .text("]") {
                let next = min(max(0,index+(key == .text("[") ? -1 : 1)),file.files.count-1)
                return read(["web","agent-review",module,file.worker,file.files[next]],kind:"file")
            }
            if key == .up { offset = max(0,offset-1) }
            if key == .down { offset += 1 }
            if key == .pageDown { offset += max(1,height-9) }
            if key == .pageUp { offset = max(0,offset-max(1,height-9)) }
            if key == .home { offset = 0; horizontal = 0 }
            if key == .end { offset = max(0,lines.count-max(1,height-9)) }
            if key == .left || key == .panLeft { horizontal = max(0,horizontal-8) }
            if key == .right || key == .panRight { horizontal += 8 }
            if case let .mouse(button,column,row,released) = key, !released {
                if button == 64 { offset = max(0,offset-3) }
                if button == 65 { offset += 3 }
                if button == 66 { horizontal = max(0,horizontal-8) }
                if button == 67 { horizontal += 8 }
                if button == 0, column < treeWidth(width)+4, row >= 5, row-5 < file.files.count {
                    return read(["web","agent-review",module,file.worker,file.files[row-5]],kind:"file")
                }
            }
            offset = min(offset,max(0,lines.count-max(1,height-9)))
            horizontal = min(horizontal,max(0,(lines.map(\.count).max() ?? 0)-max(1,width-treeWidth(width)-14)))
            return nil
        }
        if key == .up { selected = max(0,selected-1) }
        if key == .down { selected = min(max(0,rows.count-1),selected+1) }
        if key == .text("r") || key == .text("R") { return read(["web","agents",module],kind:"list") }
        if case let .mouse(button,_,row,released) = key, !released {
            if button == 64 { selected = max(0,selected-1) }
            if button == 65 { selected = min(max(0,rows.count-1),selected+1) }
            if button == 0, row >= 5 {
                let start = max(0,selected-max(1,height-10)+1), index = start+row-5
                if rows.indices.contains(index) { selected = index; return read(["web","agent-review",module,rows[index].worker],kind:"file") }
            }
        }
        if key == .enter, rows.indices.contains(selected) { return read(["web","agent-review",module,rows[selected].worker],kind:"file") }
        return nil
    }
    private var lines: [String] {
        guard let view else { return [] }
        return (tab == 0 ? view.diff : tab == 1 ? view.current ?? "(File absent from current source)" : tab == 2 ? view.proposed ?? "(Proposed deletion)" : view.base ?? "(File absent from base)").components(separatedBy:"\n")
    }
    private func treeWidth(_ width: Int) -> Int { min(28,max(14,width/4)) }
    func render(width: Int, height: Int, theme: TerminalTheme) -> String {
        func fit(_ s: String,_ count: Int) -> String { String(KilnTerminal.safe(s).prefix(max(0,count))).padding(toLength:max(0,count),withPad:" ",startingAt:0) }
        var output = ""
        func row(_ n: Int,_ text: String) { output += "\u{1b}[\(n);1H\u{1b}[0;48;5;\(theme.background);38;5;\(theme.foreground)m"+text }
        for n in 1...height { row(n,String(repeating:" ",count:width)) }
        row(1,theme.accentCode+fit(" AGENT PROPOSALS / "+module,width))
        row(2,fit(view.map { " Worker "+$0.worker.prefix(8)+" / "+$0.status+($0.conflict ? " / CONFLICT" : "") } ?? " Retained source changes / Enter inspect",width))
        if let file = view {
            let left = treeWidth(width), room = max(1,width-left-12)
            row(3,fit(" FILES",left+2)+fit(["[Diff]","[Current]","[Proposed]","[Base]"].enumerated().map { $0.offset == tab ? ">"+$0.element : $0.element }.joined(separator:" "),width-left-2))
            row(4,fit(" "+file.path+" / "+["base → proposal diff","current source","proposed source","original base"][tab],width))
            var lexer = SourceSyntax()
            let colors = lines.map { lexer.colors(KilnTerminal.safe($0),path:file.path) }
            for n in 0..<max(1,height-8) {
                let index = offset+n
                let label = n < file.files.count ? (file.files[n] == file.path ? "> " : "  ")+file.files[n] : ""
                var text = fit(label,left)+" | "
                if lines.indices.contains(index) {
                    let raw = KilnTerminal.safe(lines[index]), clipped = String(raw.dropFirst(horizontal).prefix(room))
                    text += String(format:"%4d",index+1)+(horizontal > 0 ? "<" : " ")
                    if tab == 0 {
                        let color = raw.hasPrefix("+") && !raw.hasPrefix("+++") ? 82 : raw.hasPrefix("-") && !raw.hasPrefix("---") ? 203 : theme.foreground
                        text += "\u{1b}[38;5;\(color)m"+fit(clipped,room)
                    } else { text += SourceSyntax.styled(fit(clipped,room),colors:Array(colors[index].dropFirst(min(horizontal,colors[index].count))),base:theme.foreground) }
                    text += raw.count > horizontal+room ? ">" : " "
                }
                row(n+5,text)
            }
        } else {
            let start = max(0,selected-max(1,height-10)+1)
            for (i,item) in rows.dropFirst(start).prefix(max(1,height-9)).enumerated() {
                row(i+5,(start+i == selected ? theme.accentCode : "")+fit((start+i == selected ? "> " : "  ")+item.worker.prefix(8)+"  "+item.status,width))
            }
            if rows.isEmpty { row(5," No retained agent proposals yet.") }
        }
        let footer = waiting ? "Loading..." : confirm ? "Use proposed file as a local draft? Enter stage / Esc cancel" : !error.isEmpty ? error : view != nil ? "Tab views  [ ] files  S stage draft  R refresh  Esc proposals" : "Arrows choose  Enter inspect  R refresh  Esc code"
        row(height-2,fit(footer,width)); row(height-1,fit("Staging never publishes. Edit/build the draft before Ctrl-D publish.",width))
        return output+"\u{1b}[0m"
    }
}
