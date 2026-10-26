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
        #expect(ui.handle(.enter) == [.command("ai work start \"Inspect my services\"")])
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

@Test func thinkingUsesFullTranscriptAndSurvivesAnswerAndSnapshot() {
    var ui = KilnTerminal(); ui.resize(width: 100, height: 32)
    _ = ui.handle(.text("7")); _ = ui.handle(.toggleThinking); _ = ui.handle(.text("Investigate")); _ = ui.handle(.enter)
    ui.progress(.reasoning((1...12).map { "Thinking row \($0)" }.joined(separator: "\n")))
    let running = ui.render()
    #expect(running.contains("Thinking row 1"))
    #expect(running.contains("Thinking row 12"))
    ui.progress(.snapshot("")); ui.progress(.answer("Final visible answer"))
    #expect(ui.render().contains("Thinking row 1"))
    #expect(ui.render().contains("Final visible answer"))
    ui.finish(text: "Final visible answer", status: 0)
    #expect(ui.render().contains("Thinking row 1"))
    #expect(ui.render().contains("Thinking row 12"))
    #expect(ui.render().contains("Final visible answer"))
}

@Test func scrolledThinkingStaysAnchoredAsDeltasArriveAndTurnEnds() {
    var ui = KilnTerminal(); ui.resize(width: 90, height: 24)
    _ = ui.handle(.text("7")); _ = ui.handle(.toggleThinking); _ = ui.handle(.text("Investigate")); _ = ui.handle(.enter)
    ui.progress(.reasoning((1...35).map { "Anchor row \($0)" }.joined(separator: "\n")))
    _ = ui.handle(.pageUp); _ = ui.handle(.pageUp)
    let before = ui.render()
    ui.progress(.reasoning("\nNew later row\nAnother later row"))
    let after = ui.render()
    for i in 1...35 { #expect(before.contains("Anchor row \(i) ") == after.contains("Anchor row \(i) ")) }
    #expect(!after.contains("New later row"))
    ui.finish(text: "Completed", status: 0)
    #expect(ui.render().contains("Scrolled up"))
    for _ in 0..<20 { _ = ui.handle(.pageDown) }
    #expect(ui.render().contains("Completed"))
}

@Test func thinkingLimitsAreExplicitAndScopeChangesRemovePrivateTranscript() {
    var ui = KilnTerminal(); ui.resize(width: 90, height: 24)
    ui.updateAIWorkspace(AIWorkspaceSnapshot(contextScope: "first"))
    _ = ui.handle(.text("7")); _ = ui.handle(.toggleThinking); _ = ui.handle(.text("Investigate")); _ = ui.handle(.enter)
    ui.progress(.reasoning(String(repeating: "a", count: 131073)))
    #expect(ui.render().contains("Visible thinking limit reached"))
    ui.finish(text: "PRIVATE ANSWER", status: 0)
    #expect(ui.render().contains("PRIVATE ANSWER"))
    ui.updateAIWorkspace(AIWorkspaceSnapshot(contextScope: "second"))
    #expect(!ui.render().contains("PRIVATE ANSWER"))
    #expect(!ui.render().contains("Visible thinking limit reached"))
}

@Test func answersAreReadableByDefaultWhileThinkingRemainsExpandable() {
    var ui = KilnTerminal(); ui.resize(width: 120, height: 32)
    _ = ui.handle(.text("7")); _ = ui.handle(.text("Investigate")); _ = ui.handle(.enter)
    ui.progress(.reasoning("A long technical investigation with CSS details."))
    #expect(!ui.render().contains("CSS details"))
    #expect(ui.render().contains("Ctrl-T"))
    ui.finish(text: "Published successfully. Open the preview.", status: 0)
    #expect(ui.render().contains("Published successfully"))
    #expect(!ui.render().contains("CSS details"))
    _ = ui.handle(.toggleThinking)
    #expect(ui.render().contains("CSS details"))
    _ = ui.handle(.toggleThinking)
    #expect(!ui.render().contains("CSS details"))
}
@Test func serviceReleasesAndChangesOpenVisibleScrollableViews() {
    var ui = KilnTerminal(); ui.resize(width: 140, height: 35); ui.update([sample])
    _ = ui.handle(.enter)
    for _ in 0..<5 { _ = ui.handle(.down) }
    #expect(ui.handle(.enter) == [.command("'app' 'releases' 'storefront/rest'")])
    ui.finish(text: "Active: current\nPrevious: before\nIngress: 127.0.0.1:18085", status: 0)
    #expect(ui.render().contains("Active: current"))
    _ = ui.handle(.escape); _ = ui.handle(.enter)
    for _ in 0..<6 { _ = ui.handle(.down) }
    #expect(ui.handle(.enter) == [.command("'web' 'history' 'storefront/rest'")])
    ui.finish(text: "[{\"id\":\"change-one\",\"version\":\"1\",\"status\":\"active\",\"created\":\"2026-10-25T12:00:00Z\",\"commit\":\"abcdef012345\"}]", status: 0)
    #expect(ui.render().contains("Changes / storefront/rest"))
    #expect(ui.handle(.enter) == [.command("'web' 'diff' 'storefront/rest' 'change-one'")])
    ui.finish(text: "--- Before.swift\n+++ App.swift\n-old heading\n+new heading", status: 0)
    #expect(ui.render().contains("+new heading"))
}
@Test func serviceHistoryScrollsToOlderRetainedChanges() throws {
    var ui = KilnTerminal(); ui.resize(width: 100, height: 20); ui.update([sample])
    _ = ui.handle(.enter); for _ in 0..<6 { _ = ui.handle(.down) }; _ = ui.handle(.enter)
    let rows = (0..<32).map { ["id":"c\($0)","version":"\($0)","status":"active","created":"2026-10-25","commit":"git-\($0)"] }
    ui.finish(text: String(decoding: try JSONEncoder().encode(rows), as: UTF8.self), status: 0)
    for _ in 0..<31 { _ = ui.handle(.down) }
    #expect(ui.render().contains("c31"))
    #expect(ui.handle(.enter) == [.command("'web' 'diff' 'storefront/rest' 'c31'")])
}
