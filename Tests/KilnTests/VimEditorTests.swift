import Foundation
import Testing
import KilnKit
@testable import KilnTerminal

@Test func vimModesMotionsUndoAndCommandsNeverTreatNormalTypingAsSource() {
    var vim = VimEditor(); vim.enabled = true
    var text = "first line\nsecond line\n", cursor = 0
    _ = vim.handle(.text("w"),text:&text,cursor:&cursor); #expect(cursor == 6)
    _ = vim.handle(.text("i"),text:&text,cursor:&cursor); #expect(vim.insert)
    _ = vim.handle(.escape,text:&text,cursor:&cursor); #expect(!vim.insert)
    _ = vim.handle(.text("d"),text:&text,cursor:&cursor)
    _ = vim.handle(.text("d"),text:&text,cursor:&cursor); #expect(text == "second line\n")
    _ = vim.handle(.text("u"),text:&text,cursor:&cursor); #expect(text == "first line\nsecond line\n")
    _ = vim.handle(.redo,text:&text,cursor:&cursor); #expect(text == "second line\n")
    _ = vim.handle(.text(":"),text:&text,cursor:&cursor)
    _ = vim.handle(.text("w"),text:&text,cursor:&cursor)
    if case .write = vim.handle(.enter,text:&text,cursor:&cursor) {} else { Issue.record(":w did not use guarded publication") }
    #expect(text == "second line\n")
}

private func editorFixture() throws -> WorkspaceUI {
    let source = "import Foundation\n"+String(repeating:"x",count:140)+"\nshort\n"
    var ui = WorkspaceUI(module:"demo/web")
    let file: [String:Any] = ["file":"App.swift","sha256":"a","source":source,"version":"workspace"]
    let tree: [String:Any] = ["version":"workspace","editable":true,"projectRoot":true,"files":[["path":"App.swift","sha256":"a","bytes":source.utf8.count],["path":"Views/Page.swift","sha256":"b","bytes":20]]]
    ui.finish(text:String(decoding:try JSONSerialization.data(withJSONObject:["tree":tree,"file":file]),as:UTF8.self),status:0)
    return ui
}
@Test func vimWorkspacePreservesDraftsAndUsesPublishConfirmation() throws {
    var ui = try editorFixture()
    _ = ui.handle(.vim,width:110,height:35)
    #expect(ui.render(width:110,height:35,theme:TerminalTheme()).contains("Vim NORMAL"))
    _ = ui.handle(.text("i"),width:110,height:35)
    _ = ui.handle(.text("// unsaved\n"),width:110,height:35)
    _ = ui.handle(.escape,width:110,height:35)
    #expect(ui.hasUnsavedEdits)
    #expect(!ui.render(width:110,height:35,theme:TerminalTheme()).contains("Discard unsaved"))
    _ = ui.handle(.tab,width:110,height:35); _ = ui.handle(.down,width:110,height:35)
    #expect(ui.handle(.enter,width:110,height:35) == "'web' 'file' 'demo/web' 'Views/Page.swift'")
    ui.finish(text:"{\"file\":\"Views/Page.swift\",\"sha256\":\"b\",\"source\":\"struct Page {}\",\"version\":\"workspace\"}",status:0)
    #expect(ui.hasUnsavedEdits)
    _ = ui.handle(.text(":"),width:110,height:35); _ = ui.handle(.text("w"),width:110,height:35)
    #expect(ui.handle(.enter,width:110,height:35) == nil)
    #expect(ui.render(width:110,height:35,theme:TerminalTheme()).contains("Compile and publish"))
    #expect(ui.handle(.enter,width:110,height:35) == nil) // cancel selected initially
}
@Test func horizontalGesturesMarkBothEdgesWithoutEditingSourceAndClearShortRows() throws {
    var ui = try editorFixture()
    let before = ui.hasUnsavedEdits
    _ = ui.handle(.mouse(button:67,column:70,row:8,released:false),width:90,height:25)
    let frame = ui.render(width:90,height:25,theme:TerminalTheme())
    let clean = frame.replacingOccurrences(of:"\u{1b}\\[[0-9;?]*[A-Za-z]",with:"",options:.regularExpression)
    #expect(clean.contains("2<")); #expect(clean.contains(String(repeating:"x",count:10)))
    #expect(clean.contains("Col 9")); #expect(!ui.hasUnsavedEdits && !before)
    _ = ui.handle(.mouse(button:66,column:70,row:8,released:false),width:90,height:25)
    #expect(ui.render(width:90,height:25,theme:TerminalTheme()).contains("Col 1"))
    #expect(ui.render(width:90,height:25,theme:TerminalTheme()).contains("?25h"))
    var keys = TerminalKeys()
    #expect(keys.feed(Array("\u{1b}[<67;70;8M\u{1b}[<66;70;8M\u{1b}[1;2C\u{1b}[18~".utf8)) == [.mouse(button:67,column:70,row:8,released:false),.mouse(button:66,column:70,row:8,released:false),.panRight,.vim])
}
