import Foundation
import Testing
import KilnKit
import KilnTerminal
import KilnCommands

private let sample = ModuleSnapshot(application: "storefront", name: "rest", version: "0.1.0", state: "running", pid: 123)

@Test func fragmentedKeysAndPasteAreSafe() {
    var decoder = TerminalKeys()
    #expect(decoder.feed([27,91]).isEmpty)
    #expect(decoder.feed([65]) == [.up])
    #expect(decoder.feed([27]).isEmpty)
    #expect(decoder.expireEscape() == [.escape])
    #expect(decoder.feed([27,91,50,48,48,126]).isEmpty)
    #expect(decoder.feed(Array("app stop\nrest".utf8)).isEmpty)
    #expect(decoder.feed([27,91,50,48,49,126]) == [.paste("app stop\nrest")])
    #expect(decoder.feed([0xC3]).isEmpty)
    #expect(decoder.feed([0xA9]) == [.text("é")])
}

@Test func menuConfirmsDisruptiveActionsAndDrawerEdits() {
    var ui = KilnTerminal(); ui.update([sample])
    #expect(ui.handle(.enter).isEmpty)
    #expect(ui.handle(.down).isEmpty)
    #expect(ui.handle(.enter).isEmpty) // Stop requires confirmation.
    #expect(ui.render().contains("Confirm: app stop storefront/rest"))
    #expect(ui.handle(.escape).isEmpty)
    _ = ui.handle(.text("`"))
    _ = ui.handle(.text("statu")); _ = ui.handle(.tab)
    #expect(ui.input == "status")
    #expect(ui.handle(.enter) == [.command("status")])
    #expect(ui.busy)
    ui.finish(text: "ok", status: 0)
    _ = ui.handle(.up)
    #expect(ui.input == "status")
    _ = ui.handle(.home); _ = ui.handle(.delete); _ = ui.handle(.text("s"))
    #expect(ui.input == "status")
    _ = ui.handle(.interrupt)
    _ = ui.handle(.paste("status\nexit"))
    #expect(ui.input == "status exit")
    #expect(!ui.busy)
}

@Test func layoutFitsAndUntrustedOutputCannotInjectANSI() throws {
    var ui = KilnTerminal(); ui.update([sample])
    for (width,height) in [(50,16),(80,24),(120,35),(320,120),(400,45)] {
        ui.resize(width: width,height: height)
        let ansi = try NSRegularExpression(pattern: "\u{1b}\\[[0-9;?]*[A-Za-z]")
        for drawer in [false,true] {
            if drawer { _ = ui.handle(.text("`")) }
            let frame = ui.render()
            let plain = ansi.stringByReplacingMatches(in: frame, range: NSRange(frame.startIndex...,in:frame),withTemplate: "")
            #expect(plain.components(separatedBy: "\r\n").count == height)
            #expect(plain.components(separatedBy: "\r\n").allSatisfy { $0.count == width-1 })
            if drawer { #expect(plain.contains(String(repeating: "=", count: width-5))) }
            if drawer { _ = ui.handle(.escape) }
        }
    }
    #expect(!KilnTerminal.safe("\u{1b}]52;c;evil\u{7}").contains("\u{1b}"))
    ui.resize(width: 30,height: 10)
    #expect(ui.render().contains("Terminal too small"))
}

@Test func quotedPathsAreArgumentsNotShellCode() throws {
    #expect(try KilnCommands.tokenize("app install '/tmp/my manifest.json'") == ["app","install","/tmp/my manifest.json"])
    #expect(try KilnCommands.tokenize("app install \"/tmp/$(touch evil).json\"") == ["app","install","/tmp/$(touch evil).json"])
    #expect(throws: (any Error).self) { try KilnCommands.tokenize("app install 'unfinished") }
}

@Test func mouseReportsAreIncrementalAndReleaseDoesNotActivate() {
    var decoder = TerminalKeys()
    #expect(decoder.feed(Array("\u{1b}[<0;12;".utf8)).isEmpty)
    #expect(decoder.feed(Array("4M".utf8)) == [.mouse(button: 0,column: 12,row: 4,released: false)])
    #expect(decoder.feed(Array("\u{1b}[<0;12;4m".utf8)) == [.mouse(button: 0,column: 12,row: 4,released: true)])
    var ui = KilnTerminal(); ui.update([sample]); ui.resize(width: 100,height: 30)
    #expect(ui.handle(.mouse(button: 0,column: 6,row: 9,released: true)).isEmpty)
    #expect(!ui.render().contains("Manage storefront/rest"))
    _ = ui.handle(.mouse(button: 0,column: 6,row: 9,released: false))
    #expect(ui.render().contains("Manage storefront/rest"))
    _ = ui.handle(.down); _ = ui.handle(.enter)
    #expect(ui.render().contains("Confirm:"))
    // Confirmation cancel is a distinct click target, never executes the action.
    #expect(ui.handle(.mouse(button: 0,column: 40,row: 11,released: false)).isEmpty)
    #expect(!ui.render().contains("Confirm:"))
    #expect(KilnTerminal.leaveScreen.contains("\u{1b}[?1000l"))
    #expect(KilnTerminal.leaveScreen.contains("\u{1b}[?1006l"))
}

@Test func commandShortcutLeavesChatAndKeepsCommandHistorySeparate() {
    for shortcut in ["`", "~"] {
        var ui = KilnTerminal()
        _ = ui.handle(.text(shortcut))
        _ = ui.handle(.text("status"))
        #expect(ui.handle(.enter) == [.command("status")])
        ui.finish(text: "runtime running", status: 0)
        _ = ui.handle(.escape)
        _ = ui.handle(.text("7"))
        #expect(ui.chatVisible)
        _ = ui.handle(.text("Inspect my services"))
        #expect(ui.handle(.enter) == [.command("ai ask \"Inspect my services\"")])
        ui.finish(text: "Chat result", status: 0)
        _ = ui.handle(.text("unsent chat draft"))
        _ = ui.handle(.text(shortcut))
        #expect(ui.drawer && !ui.chatVisible && ui.input.isEmpty)
        #expect(ui.render().contains("COMMAND DRAWER"))
        _ = ui.handle(.up)
        #expect(ui.input == "status")
        #expect(ui.handle(.enter) == [.command("status")])
        ui.finish(text: "runtime running", status: 0)
        _ = ui.handle(.text(shortcut))
        #expect(!ui.drawer)
        _ = ui.handle(.text("7"))
        _ = ui.handle(.up)
        #expect(ui.input == "Inspect my services")
        #expect(ui.render().contains("Chat result"))
        _ = ui.handle(.interrupt)
        _ = ui.handle(.escape)
        _ = ui.handle(.text(shortcut))
        #expect(ui.drawer && !ui.chatVisible)
    }
}

@Test func commandShortcutDuringChatPreservesTheInFlightAnswer() {
    var ui = KilnTerminal()
    _ = ui.handle(.text("7")); _ = ui.handle(.text("Inspect"))
    _ = ui.handle(.enter)
    _ = ui.handle(.text("`"))
    #expect(ui.drawer && !ui.chatVisible && ui.busy)
    ui.finish(text: "Completed chat answer", status: 0)
    _ = ui.handle(.text("`")); _ = ui.handle(.text("7"))
    #expect(ui.render().contains("Completed chat answer"))
}
