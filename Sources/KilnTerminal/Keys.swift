import Foundation

public enum TerminalKey: Equatable {
    case followAgent
    case text(String), up, down, left, right, home, end, delete, backspace, enter, escape, tab
    case selectText, toggleThinking, focusWorkspace, complete, definition, build, run, wrap, vim, redo, panLeft, panRight, pageUp, pageDown, interrupt, eof, clearBefore, clearAfter
    case paste(String)
    case mouse(button: Int, column: Int, row: Int, released: Bool)
}

/// Incremental decoder: escape sequences and UTF-8 may cross SSH packets.
public struct TerminalKeys {
    private var sequence: [UInt8] = []
    private var utf8: [UInt8] = []
    private var pasted: [UInt8]? = nil
    private var pasteTail: [UInt8] = []
    private var lastCR = false
    public init() {}
    public var awaitingEscape: Bool { !sequence.isEmpty }
    public mutating func expireEscape() -> [TerminalKey] {
        guard !sequence.isEmpty else { return [] }
        let bare = sequence == [27]; sequence = []
        return bare ? [.escape] : []
    }
    public mutating func feed(_ bytes: [UInt8]) -> [TerminalKey] {
        var keys: [TerminalKey] = []
        for byte in bytes {
            if pasted != nil {
                // Keep the end marker separate from a bounded payload. Even after
                // truncation, stay in paste mode so pasted newlines/control bytes
                // cannot become command keys.
                pasteTail.append(byte)
                if pasteTail.count > 6 {
                    let payload = pasteTail.removeFirst()
                    if pasted!.count < 16384 { pasted!.append(payload) }
                }
                if pasteTail == [27,91,50,48,49,126] {
                    keys.append(.paste(String(decoding: pasted!, as: UTF8.self)))
                    pasted = nil; pasteTail = []
                }
                continue
            }
            if !sequence.isEmpty {
                sequence.append(byte)
                if sequence == [27,91] || sequence == [27,79] { continue }
                if sequence.count == 2 { sequence = []; continue }
                if (64...126).contains(byte) {
                    let tail = String(decoding: sequence.dropFirst(), as: UTF8.self)
                    if tail.hasPrefix("[<"), tail.hasSuffix("M") || tail.hasSuffix("m") {
                        let fields = tail.dropFirst(2).dropLast().split(separator: ";").compactMap { Int($0) }
                        if fields.count == 3, fields[1] > 0, fields[2] > 0 {
                            keys.append(.mouse(button: fields[0], column: fields[1], row: fields[2], released: tail.hasSuffix("m")))
                        }
                    }
                    let key: TerminalKey? = switch tail {
                    case "[A", "OA": .up
                    case "[B", "OB": .down
                    case "[C", "OC": .right
                    case "[D", "OD": .left
                    case "[H", "OH", "[1~", "[7~": .home
                    case "[F", "OF", "[4~", "[8~": .end
                    case "[3~": .delete
                    case "[15~": .run
                    case "[17~": .wrap
                    case "[18~": .vim
                    case "[19~": .followAgent
                    case "[1;2D": .panLeft
                    case "[1;2C": .panRight
                    case "[23~": .build
                    case "[24~": .definition
                    case "[5~": .pageUp
                    case "[6~": .pageDown
                    default: nil
                    }
                    if tail == "[200~" { pasted = []; pasteTail = [] }
                    if let key { keys.append(key) }
                    sequence = []
                } else if sequence.count > 24 { sequence = [] }
                continue
            }
            if byte == 27 { sequence = [27]; utf8 = []; continue }
            if byte == 10 && lastCR { lastCR = false; continue }
            lastCR = byte == 13
            switch byte {
            case 0: keys.append(.complete)
            case 18: keys.append(.redo)
            case 19: keys.append(.selectText)
            case 20: keys.append(.toggleThinking)
            case 23: keys.append(.focusWorkspace)
            case 10,13: keys.append(.enter)
            case 127,8: keys.append(.backspace)
            case 9: keys.append(.tab)
            case 3: keys.append(.interrupt)
            case 4: keys.append(.eof)
            case 1: keys.append(.home)
            case 5: keys.append(.end)
            case 21: keys.append(.clearBefore)
            case 11: keys.append(.clearAfter)
            case 32...126: utf8 = []; keys.append(.text(String(UnicodeScalar(byte))))
            case 128...255:
                utf8.append(byte)
                if let text = String(bytes: utf8, encoding: .utf8) { keys.append(.text(text)); utf8 = [] }
                else if utf8.count >= 4 { utf8 = [] }
            default: break
            }
        }
        return keys
    }
}
