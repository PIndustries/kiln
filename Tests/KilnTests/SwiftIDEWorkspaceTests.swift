import Foundation
import Testing
import KilnKit
@testable import KilnTerminal
@testable import KilnCommands

private func ideBrowser() throws -> WorkspaceUI {
    let source = "import Foundation\nfunc demo() { let word = \"hello\"; print(word.count) }\n" + "//" + String(repeating:"x",count:140) + "\n"
    let value: [String:Any] = ["tree":["version":"workspace","editable":true,"projectRoot":true,"files":[["path":"App.swift","sha256":"a","bytes":source.count],["path":"Models/Word.swift","sha256":"b","bytes":20]]],"file":["file":"App.swift","sha256":"a","source":source,"version":"workspace"]]
    var ui = WorkspaceUI(module:"demo/web")
    ui.finish(text:String(decoding:try JSONSerialization.data(withJSONObject:value),as:UTF8.self),status:0)
    return ui
}
private func reply(_ result: SwiftIDEResult) throws -> String { String(decoding:try JSONEncoder().encode(result),as:UTF8.self) }
@Test func swiftCompletionInsertsCompilerEditAndStaleRepliesNeverOverwriteTyping() throws {
    var ui = try ideBrowser()
    let effect = ui.handle(.complete,width:110,height:35)
    let command = try #require(effect)
    let args = try KilnCommands.tokenize(command)
    #expect(Array(args.prefix(3)) == ["web","ide","demo/web"])
    let request = try JSONDecoder().decode(SwiftIDERequest.self,from:Data(args[3].utf8))
    #expect(request.action == "complete" && request.path == "App.swift")
    var result = SwiftIDEResult(action:"complete",message:"Swift completions")
    result.completions = [SwiftIDECompletion(label:"let",detail:"keyword",text:"// inserted\n",start:0,end:0)]
    ui.finish(text:try reply(result),status:0)
    _ = ui.handle(.enter,width:110,height:35)
    #expect(ui.render(width:110,height:35,theme:TerminalTheme()).contains("inserted"))
    _ = ui.handle(.complete,width:110,height:35)
    _ = ui.handle(.text("new typing"),width:110,height:35)
    ui.finish(text:try reply(result),status:0)
    let frame = ui.render(width:110,height:35,theme:TerminalTheme())
    #expect(frame.contains("typing")); #expect(frame.contains("earlier buffer"))
}
@Test func definitionAndClickableCompilerErrorsPreserveLocalBuffers() throws {
    var ui = try ideBrowser()
    _ = ui.handle(.text("e"),width:110,height:35)
    _ = ui.handle(.text("// unsaved\n"),width:110,height:35)
    _ = ui.handle(.definition,width:110,height:35)
    var result = SwiftIDEResult(action:"definition",message:"Swift definitions")
    result.locations = [SwiftIDELocation(path:"Models/Word.swift",line:1,column:8)]
    ui.finish(text:try reply(result),status:0)
    let openEffect = ui.handle(.enter,width:110,height:35)
    let open = try #require(openEffect)
    #expect(open == "'web' 'file' 'demo/web' 'Models/Word.swift'")
    ui.finish(text:"{\"file\":\"Models/Word.swift\",\"sha256\":\"b\",\"source\":\"struct Word {}\\n\",\"version\":\"workspace\"}",status:0)
    #expect(ui.hasUnsavedEdits)
    // The tree can return to the original draft.
    _ = ui.handle(.tab,width:110,height:35); _ = ui.handle(.up,width:110,height:35)
    #expect(ui.handle(.enter,width:110,height:35) == "'web' 'file' 'demo/web' 'App.swift'")
    ui.finish(text:"{\"file\":\"App.swift\",\"sha256\":\"a\",\"source\":\"import Foundation\\nfunc demo() { let word = \\\"hello\\\"; print(word.count) }\\n\",\"version\":\"workspace\"}",status:0)
    #expect(ui.render(width:110,height:35,theme:TerminalTheme()).contains("unsaved"))
    _ = ui.handle(.build,width:110,height:35)
    var build = SwiftIDEResult(action:"build",message:"Build failed")
    build.locations = [SwiftIDELocation(path:"App.swift",line:2,column:1,message:"error: test")]
    ui.finish(text:try reply(build),status:0)
    _ = ui.handle(.mouse(button:0,column:10,row:7,released:false),width:110,height:35)
    #expect(ui.render(width:110,height:35,theme:TerminalTheme()).contains("unsaved"))
    #expect(ui.handle(.run,width:110,height:35) == nil)
    #expect(ui.render(width:110,height:35,theme:TerminalTheme()).contains("Publish drafts"))
}
@Test func sourceScrollingDefaultsToNoWrapAndWrapCanBeToggledWithoutEditing() throws {
    var ui = try ideBrowser()
    let original = ui.contextJSON
    let frame = ui.render(width:80,height:35,theme:TerminalTheme())
    #expect(frame.contains("Wrap OFF"))
    _ = ui.handle(.tab,width:80,height:35); _ = ui.handle(.right,width:80,height:35)
    #expect(ui.render(width:80,height:35,theme:TerminalTheme()).contains("Col 9"))
    _ = ui.handle(.wrap,width:80,height:35)
    #expect(ui.render(width:80,height:35,theme:TerminalTheme()).contains("Wrap ON"))
    _ = ui.handle(.wrap,width:80,height:35)
    #expect(ui.render(width:80,height:35,theme:TerminalTheme()).contains("Wrap OFF"))
    let before = try JSONDecoder().decode([String:String].self,from:Data((original ?? "").utf8))
    let after = try JSONDecoder().decode([String:String].self,from:Data((ui.contextJSON ?? "").utf8))
    #expect(after == before)
    #expect(!ui.hasUnsavedEdits)
}
@Test func swiftIDEShortcutsDecodeWithoutBeingInsertedIntoTheFile() {
    var keys = TerminalKeys()
    #expect(keys.feed([0]) == [.complete])
    #expect(keys.feed(Array("\u{1b}[15~\u{1b}[17~\u{1b}[23~\u{1b}[24~".utf8)) == [.run,.wrap,.build,.definition])
}

@Test func publicationIncludesPendingFilesAsOneValidatedChange() throws {
    var ui = try ideBrowser()
    _ = ui.handle(.text("e"),width:110,height:35)
    _ = ui.handle(.text("// first draft\n"),width:110,height:35)
    _ = ui.handle(.definition,width:110,height:35)
    var result = SwiftIDEResult(action:"definition",message:"Swift definitions")
    result.locations = [SwiftIDELocation(path:"Models/Word.swift",line:1,column:1)]
    ui.finish(text:try reply(result),status:0)
    _ = ui.handle(.enter,width:110,height:35)
    ui.finish(text:"{\"file\":\"Models/Word.swift\",\"sha256\":\"b\",\"source\":\"struct Word {}\\n\",\"version\":\"workspace\"}",status:0)
    _ = ui.handle(.text("e"),width:110,height:35)
    _ = ui.handle(.text("// second draft\n"),width:110,height:35)
    _ = ui.handle(.build,width:110,height:35)
    let build = SwiftIDEResult(action:"build",message:"Build passed")
    ui.finish(text:try reply(build),status:0); _ = ui.handle(.escape,width:110,height:35)
    _ = ui.handle(.eof,width:110,height:35); _ = ui.handle(.down,width:110,height:35)
    let effect = ui.handle(.enter,width:110,height:35)
    let command = try #require(effect)
    let parts = try KilnCommands.tokenize(command)
    let edits = try JSONDecoder().decode([[String:String]].self,from:Data(parts[3].utf8))
    #expect(edits.count == 2)
    #expect(edits.first?["path"] == "App.swift" && edits.first?["sha256"] == "a")
    #expect(edits.last?["path"] == "Models/Word.swift" && edits.last?["sha256"] == "b")
}

@Test func wrappedSourceContextUsesSourceLinesRatherThanScreenRows() throws {
    var ui = try ideBrowser()
    _ = ui.handle(.wrap,width:50,height:16)
    _ = ui.handle(.end,width:50,height:16)
    let json = try #require(ui.contextJSON(width:50))
    let context = try JSONDecoder().decode([String:String].self,from:Data(json.utf8))
    let first = try #require(context["firstVisibleLine"].flatMap(Int.init))
    #expect(first <= 4)
}

@Test func automaticCompletionWorksWhileTypingInStandardAndVimInsertModes() throws {
    for modal in [false,true] {
        var ui = try ideBrowser()
        if modal {
            _ = ui.handle(.vim,width:110,height:35)
            _ = ui.handle(.text("i"),width:110,height:35)
        } else { _ = ui.handle(.text("e"),width:110,height:35) }
        #expect(ui.handle(.text("Str"),width:110,height:35) == nil)
        let effect = ui.completeAfterTyping()
        let command = try #require(effect)
        let parts = try KilnCommands.tokenize(command)
        let request = try JSONDecoder().decode(SwiftIDERequest.self,from:Data(parts[3].utf8))
        #expect(request.text.hasPrefix("Str") && request.cursor == 3)
        #expect(ui.completeAfterTyping() == nil)
        // More typing during the request must neither be blocked nor overwritten.
        _ = ui.handle(.text("i"),width:110,height:35)
        var result = SwiftIDEResult(action:"complete",message:"Swift completions")
        result.completions = [SwiftIDECompletion(label:"String",detail:"struct",text:"String",start:0,end:3)]
        ui.finish(text:try reply(result),status:0)
        #expect(!ui.render(width:110,height:35,theme:TerminalTheme()).contains("earlier buffer"))
        #expect(ui.completeAfterTyping() != nil)
        result.completions = [SwiftIDECompletion(label:"String",detail:"struct",text:"String",start:0,end:4)]
        ui.finish(text:try reply(result),status:0)
        let frame = ui.render(width:110,height:35,theme:TerminalTheme())
        #expect(frame.contains("Suggestions:") && frame.contains("func"))
        _ = ui.handle(.tab,width:110,height:35)
        #expect(!ui.render(width:110,height:35,theme:TerminalTheme()).contains("Suggestions:"))
        let nextEffect = ui.handle(.complete,width:110,height:35)
        let next = try #require(nextEffect)
        let args = try KilnCommands.tokenize(next)
        let inserted = try JSONDecoder().decode(SwiftIDERequest.self,from:Data(args[3].utf8))
        #expect(inserted.text.hasPrefix("Stringimport"))
    }
}
@Test func automaticCompletionDismissalEmptyResultsAndPasteDoNotInterruptEditing() throws {
    var ui = try ideBrowser()
    _ = ui.handle(.text("e"),width:110,height:35)
    _ = ui.handle(.paste("Many words"),width:110,height:35)
    #expect(ui.completeAfterTyping() == nil)
    _ = ui.handle(.text("X"),width:110,height:35)
    #expect(ui.completeAfterTyping() != nil)
    ui.finish(text:try reply(SwiftIDEResult(action:"complete",message:"no completions")),status:0)
    #expect(!ui.render(width:110,height:35,theme:TerminalTheme()).contains("no completions"))
    _ = ui.handle(.text("Y"),width:110,height:35)
    _ = ui.handle(.left,width:110,height:35)
    #expect(ui.completeAfterTyping() == nil)
    _ = ui.handle(.vim,width:110,height:35)
    _ = ui.handle(.text("i"),width:110,height:35)
    _ = ui.handle(.text("Z"),width:110,height:35)
    #expect(ui.completeAfterTyping() != nil)
    _ = ui.handle(.escape,width:110,height:35)
    var result = SwiftIDEResult(action:"complete",message:"Swift completions")
    result.completions = [SwiftIDECompletion(label:"Zombie",detail:"",text:"Zombie",start:0,end:1)]
    ui.finish(text:try reply(result),status:0)
    #expect(!ui.render(width:110,height:35,theme:TerminalTheme()).contains("Suggestions:"))
}
