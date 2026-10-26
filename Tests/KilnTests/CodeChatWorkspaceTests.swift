import Foundation
import Testing
import KilnKit
@testable import KilnTerminal
@testable import KilnCommands

private func codeFixture() throws -> String {
    let source = (1...100).map { "let line\($0) = \($0)" }.joined(separator: "\n")
    return String(decoding: try JSONSerialization.data(withJSONObject: [
        "tree": ["version":"workspace", "editable":true, "projectRoot":true,
                 "files":[["path":"App.swift","sha256":String(repeating:"a",count:64),"bytes":source.utf8.count],
                          ["path":"Models/Counter.swift","sha256":String(repeating:"b",count:64),"bytes":20]]],
        "file": ["file":"App.swift","sha256":String(repeating:"a",count:64),"source":source,"version":"workspace"]
    ]), as: UTF8.self)
}
private func codeUI(width: Int = 160) throws -> KilnTerminal {
    var ui = KilnTerminal(); ui.resize(width:width,height:35)
    ui.update([ModuleSnapshot(application:"demo",name:"web",version:"1",state:"running",pid:42)])
    _ = ui.handle(.enter)
    for _ in 0..<8 { _ = ui.handle(.down) }
    #expect(ui.handle(.enter) == [.workspaceRead("'web' 'workspace' 'demo/web' 'App.swift'")])
    ui.finishWorkspace(text:try codeFixture(),status:0)
    return ui
}
private func sentContext(_ effects: [TerminalEffect]) throws -> [String:String] {
    guard case .command(let command) = try #require(effects.first) else { Issue.record("Expected chat command"); return [:] }
    let args = try KilnCommands.tokenize(command)
    #expect(Array(args.prefix(4)) == ["ai","work","start","--workspace"])
    return try JSONDecoder().decode([String:String].self,from:Data(args[4].utf8))
}
@Test func codeChatBindsTheDisplayedFileAndKeepsBrowsingIndependentOfStreaming() throws {
    var ui = try codeUI()
    let frame = ui.render()
    #expect(frame.contains("Codebase / demo/web")); #expect(frame.contains("KILN AI CHAT"))
    #expect(frame.contains("App: demo/web | App.swift")); #expect(frame.contains("Models/"))
    _ = ui.handle(.focusWorkspace); _ = ui.handle(.text("Explain this file"))
    let context = try sentContext(ui.handle(.enter))
    #expect(context["module"] == "demo/web"); #expect(context["path"] == "App.swift")
    #expect(context["sha256"] == String(repeating:"a",count:64)); #expect(context["unsaved"] == "false")
    ui.progress(.answer("AI is still responding"))
    _ = ui.handle(.focusWorkspace); _ = ui.handle(.down)
    #expect(ui.handle(.enter) == [.workspaceRead("'web' 'file' 'demo/web' 'Models/Counter.swift'")])
    let file = "{\"file\":\"Models/Counter.swift\",\"sha256\":\"\(String(repeating:"b",count:64))\",\"source\":\"actor Counter {}\",\"version\":\"workspace\"}"
    ui.finishWorkspace(text:file,status:0)
    #expect(ui.busy); #expect(ui.render().contains("AI is still responding"))
    #expect(ui.render().contains("App: demo/web | Models/Counter.swift"))
    ui.finish(text:"Finished",status:0)
    _ = ui.handle(.focusWorkspace); _ = ui.handle(.text("Now explain this one"))
    #expect(try sentContext(ui.handle(.enter))["path"] == "Models/Counter.swift")
}
@Test func codeChatPreservesUnsavedBuffersScrollAndCopyMode() throws {
    var ui = try codeUI()
    _ = ui.handle(.pageDown)
    #expect(!ui.render().contains("Lines 1-"))
    _ = ui.handle(.text("e")); _ = ui.handle(.text("// unsaved draft\n"))
    _ = ui.handle(.focusWorkspace); _ = ui.handle(.text("Explain my current file"))
    #expect(try sentContext(ui.handle(.enter))["unsaved"] == "true")
    #expect(ui.refreshCodeWorkspace() == nil)
    ui.finish(text:"Explanation",status:0)
    #expect(ui.render().contains("unsaved draft"))
    #expect(ui.handle(.selectText) == [.selectText(true)])
    #expect(ui.handle(.text("ignored")).isEmpty)
    #expect(ui.handle(.selectText) == [.selectText(false)])
    #expect(ui.render().contains("unsaved draft"))
}
@Test func codeChatNarrowResizeAndRevocationNeverExposeStaleSource() throws {
    var ui = try codeUI(width:80)
    #expect(ui.render().contains("Codebase / demo/web"))
    _ = ui.handle(.focusWorkspace)
    #expect(ui.render().contains("App: demo/web | App.swift"))
    ui.resize(width:160,height:35)
    #expect(ui.render().contains("Codebase / demo/web"))
    ui.updateAIWorkspace(AIWorkspaceSnapshot(error:"Identity revoked or unauthorized"))
    #expect(!ui.render().contains("let line")); #expect(!ui.render().contains("Codebase / demo/web"))
}
@Test func codeChatNeverSendsContextFromAnUnloadedFile() throws {
    var ui = try codeUI()
    _ = ui.handle(.down); _ = ui.handle(.enter) // read still pending
    _ = ui.handle(.focusWorkspace); _ = ui.handle(.text("Explain"))
    #expect(ui.handle(.enter).isEmpty)
    #expect(ui.input == "Explain")
    #expect(!ui.busy)
}
@Test func workspaceFocusShortcutDecodesAcrossSSHInput() {
    var keys = TerminalKeys()
    #expect(keys.feed([23]) == [.focusWorkspace])
}

@Test func codeChatSurvivesUnrelatedSessionServiceFailureAndRefreshKeepsScroll() throws {
    var ui = try codeUI()
    _ = ui.handle(.pageDown)
    let before = ui.render()
    ui.updateManagement(ManagementSnapshot(error:"Session service unavailable; terminal state is unknown."))
    #expect(ui.render().contains("Codebase / demo/web"))
    #expect(ui.refreshCodeWorkspace() != nil)
    ui.finishWorkspace(text:try codeFixture(),status:0)
    #expect(ui.render() == before)
}

private func dividerColumn(_ ui: KilnTerminal, height: Int = 35) throws -> Int {
    // The explicit center grip is unique; source/chat text is sanitized separately.
    let regex = try NSRegularExpression(pattern: "\\u001B\\[" + String(height/2) + ";(\\d+)H\\u001B\\[38;5;\\d+m\\+")
    let frame = ui.render()
    let match = try #require(regex.firstMatch(in:frame,range:NSRange(frame.startIndex...,in:frame)))
    return try #require(Range(match.range(at:1),in:frame).flatMap { Int(frame[$0]) })
}
private func dragDivider(_ ui: inout KilnTerminal, from: Int, to: Int, row: Int = 15) {
    #expect(ui.handle(.mouse(button:0,column:from,row:row,released:false)).isEmpty)
    #expect(ui.handle(.mouse(button:32,column:to,row:row,released:false)).isEmpty)
    #expect(ui.handle(.mouse(button:0,column:to,row:row,released:true)).isEmpty)
}
@Test func dividerDragResizesBothPanesAndKeepsItsProportionAcrossTerminalSizes() throws {
    var ui = try codeUI()
    #expect(try dividerColumn(ui) == 96)
    dragDivider(&ui,from:96,to:110)
    #expect(try dividerColumn(ui) == 110)
    #expect(ui.render().contains("Codebase / demo/web")); #expect(ui.render().contains("KILN AI CHAT"))
    ui.resize(width:240,height:35)
    #expect(try dividerColumn(ui) == 165)
    ui.resize(width:80,height:35)
    #expect(ui.render().contains("Codebase / demo/web"))
    ui.resize(width:160,height:35)
    #expect(try dividerColumn(ui) == 110)
    // A motion after release does not continue resizing.
    _ = ui.handle(.mouse(button:32,column:60,row:15,released:false))
    #expect(try dividerColumn(ui) == 110)
}
@Test func dividerClampsWidthsAndPreservesDraftComposerAndCopySelection() throws {
    var ui = try codeUI()
    _ = ui.handle(.text("e")); _ = ui.handle(.text("// preserved draft\n"))
    _ = ui.handle(.focusWorkspace); _ = ui.handle(.text("unfinished message"))
    dragDivider(&ui,from:96,to:159)
    #expect(try dividerColumn(ui) == 120) // chat keeps 40 columns
    #expect(ui.input == "unfinished message")
    dragDivider(&ui,from:120,to:1)
    #expect(try dividerColumn(ui) == 50)
    #expect(ui.render().contains("preserved"))
    _ = ui.handle(.selectText)
    dragDivider(&ui,from:50,to:100)
    #expect(try dividerColumn(ui) == 50)
    _ = ui.handle(.selectText)
    dragDivider(&ui,from:50,to:90)
    #expect(try dividerColumn(ui) == 90)
    #expect(ui.input == "unfinished message")
    #expect(ui.render().contains("preserved"))
    #expect(ui.refreshCodeWorkspace() == nil)
}
@Test func dividerRemainsUsableDuringInferenceWithoutChangingTurnContext() throws {
    var ui = try codeUI()
    _ = ui.handle(.focusWorkspace); _ = ui.handle(.text("Explain"))
    let context = try sentContext(ui.handle(.enter))
    ui.progress(.answer("Still responding"))
    dragDivider(&ui,from:96,to:75)
    #expect(ui.busy && ui.render().contains("Still responding"))
    #expect(try dividerColumn(ui) == 75)
    #expect(context["path"] == "App.swift")
    ui.finish(text:"Completed",status:0)
    #expect(try dividerColumn(ui) == 75)
}
@Test func dragTrackingModesAreReleasedWithTheTerminal() {
    #expect(KilnTerminal.enterScreen.contains("\u{1b}[?1002h"))
    #expect(KilnTerminal.leaveScreen.contains("\u{1b}[?1002l"))
    var keys = TerminalKeys()
    #expect(keys.feed(Array("\u{1b}[<32;110;15M\u{1b}[<0;110;15m".utf8)) == [
        .mouse(button:32,column:110,row:15,released:false), .mouse(button:0,column:110,row:15,released:true)])
}

@Test func workspaceRepliesForOtherApplicationsCannotReplaceVisibleSource() throws {
    var ui = try codeUI()
    let before = ui.render()
    ui.finishWorkspace(text:"Unavailable private source",status:1,module:"other/application")
    #expect(ui.render() == before)
    ui.finishWorkspace(text:"Current workspace failure",status:1,module:"demo/web")
    #expect(ui.render().contains("Current workspace failure"))
}
