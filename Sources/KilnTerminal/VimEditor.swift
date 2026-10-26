import Foundation

/// Deliberately small modal editing layer. It never publishes or quits directly;
/// :w and :q return actions to the workspace's existing guarded lifecycle.
struct VimEditor {
    var enabled = false
    var insert = false
    var command: String?
    private var pending = ""
    private var undo: [(String,Int)] = [], redo: [(String,Int)] = []
    var label: String { !enabled ? "Vim OFF" : command.map { ":"+$0 } ?? (insert ? "Vim INSERT" : "Vim NORMAL") }
    mutating func reset() { insert = false; command = nil; pending = ""; undo = []; redo = [] }
    mutating func record(_ text: String, _ cursor: Int) {
        guard enabled else { return }
        if undo.last?.0 != text { undo.append((text,cursor)) }
        while undo.count > 50 || undo.reduce(0, { $0+$1.0.utf8.count }) > 1_048_576 { undo.removeFirst() }
        redo = []
    }
    enum Action { case key(TerminalKey), handled, write, quit, wrap(Bool), disable, notice(String) }
    mutating func handle(_ key: TerminalKey, text: inout String, cursor: inout Int) -> Action {
        guard enabled else { return .key(key) }
        if var value = command {
            if key == .escape { command = nil; return .handled }
            if key == .backspace { if !value.isEmpty { value.removeLast() }; command = value; return .handled }
            if case .text(let input) = key, value.count < 80 { command = value+input; return .handled }
            if key == .enter {
                command = nil
                switch value {
                case "w": return .write
                case "q": return .quit
                case "set wrap": return .wrap(true)
                case "set nowrap": return .wrap(false)
                case "set novim": return .disable
                default: return .notice("Vim commands: :w  :q  :set wrap/nowrap/novim")
                }
            }
            return .handled
        }
        if key == .escape { insert = false; pending = ""; return .handled }
        if insert { return .key(key) }
        if key == .enter { return .key(.down) }
        if key == .backspace { return .key(.left) }
        if key == .redo {
            if let saved = redo.popLast() { undo.append((text,cursor)); text = saved.0; cursor = saved.1 }
            return .key(.text(""))
        }
        guard case .text(let input) = key else {
            if case .paste = key { return .notice("Press i to insert pasted text") }
            return .key(key)
        }
        let chars = Array(text); cursor = min(cursor,chars.count)
        let start = chars[..<cursor].lastIndex(of:"\n").map { $0+1 } ?? 0
        let end = chars[cursor...].firstIndex(of:"\n") ?? chars.count
        let previous = pending; pending = ""
        switch input {
        case "i": insert = true; return .handled
        case "a": insert = true; cursor = min(end,cursor+1)
        case "I": insert = true; cursor = start
        case "A": insert = true; cursor = end
        case "h": return .key(.left)
        case "j": return .key(.down)
        case "k": return .key(.up)
        case "l": return .key(.right)
        case "0": cursor = start
        case "$": cursor = end
        case "g": if previous == "g" { cursor = 0 } else { pending = "g"; return .handled }
        case "G": cursor = chars.count
        case "w":
            while cursor < chars.count && !chars[cursor].isWhitespace { cursor += 1 }
            while cursor < chars.count && chars[cursor].isWhitespace { cursor += 1 }
        case "b":
            if cursor > 0 { cursor -= 1 }
            while cursor > 0 && chars[cursor].isWhitespace { cursor -= 1 }
            while cursor > 0 && !chars[cursor-1].isWhitespace { cursor -= 1 }
        case "x": return .key(.delete)
        case "o", "O":
            guard text.utf8.count < 65536 else { return .notice("File limit is 64 KiB") }
            record(text,cursor); var edited = chars
            if input == "o" { edited.insert("\n",at:end); cursor = end+1 }
            else { edited.insert("\n",at:start); cursor = start }
            text = String(edited); insert = true
        case "d":
            if previous != "d" { pending = "d"; return .handled }
            record(text,cursor); var edited = chars
            let range = start..<(end < chars.count ? end+1 : end)
            edited.removeSubrange(range); text = String(edited); cursor = min(start,edited.count)
        case "u":
            if let saved = undo.popLast() { redo.append((text,cursor)); text = saved.0; cursor = saved.1 }
        case ":": command = ""; return .handled
        default: return .notice("Vim NORMAL: i insert  hjkl move  w/b  0/$  gg/G  x/dd  u  Ctrl-R  :w/:q")
        }
        return .key(.text(""))
    }
}
