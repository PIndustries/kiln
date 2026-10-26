import Foundation
import Testing
import KilnKit
@testable import KilnDevelopment
@testable import KilnTerminal
@testable import KilnCommands

private func languageEditor() throws -> WorkspaceUI {
    let text = "struct Item {}\nlet item = Item()\n"
    let object: [String:Any] = ["tree":["version":"workspace","editable":true,"projectRoot":true,"files":[["path":"App.swift","sha256":"a","bytes":text.count],["path":"Models/Other.swift","sha256":"b","bytes":16]]],"file":["file":"App.swift","sha256":"a","source":text,"version":"workspace"]]
    var ui = WorkspaceUI(module:"demo/web")
    ui.finish(text:String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self),status:0); return ui
}
private func languageReply(_ result: SwiftIDEResult) throws -> String { String(decoding:try JSONEncoder().encode(result),as:UTF8.self) }
@Test func liveDiagnosticsMarkSourceWithoutReplacingTheEditorAndRejectStaleText() throws {
    var ui = try languageEditor()
    _ = ui.handle(.text("e"),width:120,height:35); _ = ui.handle(.text("x"),width:120,height:35)
    let effect = ui.diagnoseAfterTyping(), command = try #require(effect)
    let parts = try KilnCommands.tokenize(command), request = try JSONDecoder().decode(SwiftIDERequest.self,from:Data(parts[3].utf8))
    #expect(request.action == "diagnostics")
    var result = SwiftIDEResult(action:"diagnostics",message:"Swift diagnostics")
    result.locations = [SwiftIDELocation(path:"App.swift",line:1,column:1,message:"error: test diagnostic")]
    // Caret movement alone does not invalidate diagnostics for unchanged text.
    _ = ui.handle(.right,width:120,height:35)
    ui.finish(text:try languageReply(result),status:0)
    let frame = ui.render(width:120,height:35,theme:TerminalTheme())
    #expect(frame.contains("1 issues [F4]")); #expect(frame.contains("Item"))
    #expect(frame.contains("\u{1b}[38;5;203m"))
    _ = ui.handle(.text("y"),width:120,height:35)
    #expect(!ui.render(width:120,height:35,theme:TerminalTheme()).contains("1 issues"))
    #expect(ui.diagnoseAfterTyping() != nil)
    _ = ui.handle(.text("z"),width:120,height:35)
    ui.finish(text:try languageReply(result),status:0)
    #expect(!ui.render(width:120,height:35,theme:TerminalTheme()).contains("1 issues"))
}
@Test func swiftRenameIsAnExplicitMultiFileDraftTransactionAndDoesNotPublishItself() throws {
    var ui = try languageEditor()
    _ = ui.handle(.text("e"),width:120,height:35); _ = ui.handle(.text("// personal\n"),width:120,height:35)
    _ = ui.handle(.rename,width:120,height:35)
    #expect(ui.hasUnsavedEdits)
    #expect(ui.render(width:120,height:35,theme:TerminalTheme()).contains("New Swift name"))
    _ = ui.handle(.text("Product"),width:120,height:35)
    let effect = ui.handle(.enter,width:120,height:35), command = try #require(effect)
    let parts = try KilnCommands.tokenize(command), request = try JSONDecoder().decode(SwiftIDERequest.self,from:Data(parts[3].utf8))
    #expect(request.action == "rename" && request.newName == "Product")
    #expect(request.text.contains("personal"))
    var result = SwiftIDEResult(action:"rename",message:"Rename proposal")
    result.renameFiles = ["App.swift":SwiftIDERenameFile(source:"struct Item {}\nlet item = Item()\n",sha256:"a",text:"// personal\nstruct Product {}\nlet item = Product()\n"),"Models/Other.swift":SwiftIDERenameFile(source:"let other = Item()",sha256:"b",text:"let other = Product()")]
    ui.finish(text:try languageReply(result),status:0)
    #expect(ui.handle(.enter,width:120,height:35) == nil)
    #expect(ui.render(width:120,height:35,theme:TerminalTheme()).contains("Product"))
    _ = ui.handle(.eof,width:120,height:35); _ = ui.handle(.down,width:120,height:35)
    let publish = ui.handle(.enter,width:120,height:35), publishCommand = try #require(publish)
    let publishParts = try KilnCommands.tokenize(publishCommand)
    #expect(Array(publishParts.prefix(3)) == ["web","apply","demo/web"])
    let operations = try JSONDecoder().decode([[String:String]].self,from:Data(publishParts[3].utf8))
    #expect(Set(operations.compactMap { $0["path"] }) == ["App.swift","Models/Other.swift"])
    #expect(operations.first { $0["path"] == "App.swift" }?["sha256"] == "a")
    #expect(operations.first { $0["path"] == "Models/Other.swift" }?["sha256"] == "b")
}
@Test func staleRenameProposalNeverOverwritesNewTyping() throws {
    var ui = try languageEditor()
    _ = ui.handle(.rename,width:120,height:35); _ = ui.handle(.text("Product"),width:120,height:35)
    _ = ui.handle(.enter,width:120,height:35); _ = ui.handle(.text("// newer\n"),width:120,height:35)
    var result = SwiftIDEResult(action:"rename",message:"Rename proposal")
    result.renameFiles = ["App.swift":SwiftIDERenameFile(source:"old",sha256:"a",text:"stale replacement")]
    ui.finish(text:try languageReply(result),status:0)
    let frame = ui.render(width:120,height:35,theme:TerminalTheme())
    #expect(frame.contains("newer")); #expect(!frame.contains("stale replacement"))
}
@Test func renameRejectsEscapedFilesResourceOperationsAndOverlappingRanges() async throws {
    let root = URL(fileURLWithPath:"/tmp/kiln-rename-parser-"+UUID().uuidString)
    let dev = WebDevelopment(directory:root), snapshot = WebFiles(files:["App.swift":Data("let value = 1\n".utf8)])
    let request = SwiftIDERequest(action:"rename",path:"App.swift",sha256:"a",text:"let value = 1\n",cursor:4,newName:"renamed")
    let range: [String:Any] = ["start":["line":0,"character":4],"end":["line":0,"character":9]]
    let edit: [String:Any] = ["range":range,"newText":"renamed"]
    let uri = root.appendingPathComponent("Sources/App.swift").absoluteString
    for raw: [String:Any] in [["changes":["file:///tmp/outside.swift":[edit]]],["documentChanges":[["kind":"delete","uri":uri]]],["changes":[uri:[edit,edit]]]] {
        do { _ = try dev.renameResult(raw,request:request,snapshot:snapshot,disk:snapshot,root:root,result:SwiftIDEResult(action:"rename",message:"test")); Issue.record("Unsafe rename accepted") } catch {}
    }
    #expect(!FileManager.default.fileExists(atPath:root.path))
}
@Test func swiftLanguageShortcutsDecodeIndependentlyOfVimMode() {
    var decoder = TerminalKeys()
    #expect(decoder.feed(Array("\u{1b}[20~\u{1b}[21~\u{1b}[14~".utf8)) == [.references,.rename,.diagnostics])
}
@Test func aPendingLanguageReadDoesNotBlockBrowsingOrTrackpadScrolling() throws {
    let text = (1...100).map { "let line\($0) = \($0)" }.joined(separator:"\n")
    let object: [String:Any] = ["tree":["version":"workspace","editable":true,"projectRoot":true,"files":[["path":"App.swift","sha256":"a","bytes":text.count]]],"file":["file":"App.swift","sha256":"a","source":text,"version":"workspace"]]
    var ui = WorkspaceUI(module:"demo/web")
    ui.finish(text:String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self),status:0)
    #expect(ui.handle(.diagnostics,width:120,height:35) != nil)
    _ = ui.handle(.end,width:120,height:35)
    let end = ui.render(width:120,height:35,theme:TerminalTheme())
    #expect(!end.contains("Lines 1-"))
    _ = ui.handle(.mouse(button:64,column:80,row:10,released:false),width:120,height:35)
    #expect(ui.render(width:120,height:35,theme:TerminalTheme()) != end)
}

@Test(arguments:[false,true]) func publicationDuringBackgroundDiagnosticsRetainsExplicitReviewAndCancellation(cancel: Bool) throws {
    var ui = try languageEditor()
    _ = ui.handle(.text("e"),width:120,height:35); _ = ui.handle(.text("// queued draft\n"),width:120,height:35)
    let request = ui.diagnoseAfterTyping(); #expect(request != nil)
    #expect(ui.handle(.eof,width:120,height:35) == nil)
    #expect(ui.render(width:120,height:35,theme:TerminalTheme()).contains("Waiting for Swift tools"))
    if cancel { _ = ui.handle(.escape,width:120,height:35) }
    ui.finish(text:try languageReply(SwiftIDEResult(action:"diagnostics",message:"No diagnostics")),status:0)
    let frame = ui.render(width:120,height:35,theme:TerminalTheme())
    #expect(frame.contains("Compile and publish") == !cancel)
    #expect(ui.hasUnsavedEdits)
    if !cancel {
        #expect(ui.handle(.enter,width:120,height:35) == nil)
        #expect(!ui.render(width:120,height:35,theme:TerminalTheme()).contains("Compile and publish"))
        #expect(ui.hasUnsavedEdits)
    }
}
