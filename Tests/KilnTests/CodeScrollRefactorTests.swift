import Foundation
import Testing
import KilnKit
import KilnAI
@testable import KilnTerminal

private func scrollFixture(_ source: String, readOnly: Bool = false) throws -> String {
    let file: [String:Any] = ["file":"App.swift","sha256":"shown-source-hash","source":source,"version":"workspace"]
    let tree: [String:Any] = ["version":"workspace","editable":!readOnly,"projectRoot":true,"files":[["path":"App.swift","sha256":"shown-source-hash","bytes":source.utf8.count]]]
    return String(decoding:try JSONSerialization.data(withJSONObject:["tree":tree,"file":file]),as:UTF8.self)
}
private func unstyled(_ text: String) -> String { text.replacingOccurrences(of:"\u{1b}\\[[0-9;?]*[A-Za-z]",with:"",options:.regularExpression) }
@Test func codeWheelAndVisiblePagingControlsScrollTheCodePaneWithoutTab() throws {
    var browser = WorkspaceUI(module:"demo/web")
    browser.finish(text:try scrollFixture((0..<100).map { "let line\($0) = \($0)" }.joined(separator:"\n")),status:0)
    #expect(unstyled(browser.render(width:120,height:25,theme:TerminalTheme())).contains("Lines 1-17/100"))
    _ = browser.handle(.mouse(button:65,column:90,row:12,released:false),width:120,height:25)
    #expect(unstyled(browser.render(width:120,height:25,theme:TerminalTheme())).contains("Lines 4-20/100"))
    _ = browser.handle(.down,width:120,height:25)
    #expect(unstyled(browser.render(width:120,height:25,theme:TerminalTheme())).contains("Lines 5-21/100"))
    _ = browser.handle(.home,width:120,height:25)
    _ = browser.handle(.mouse(button:0,column:13,row:23,released:false),width:120,height:25)
    #expect(unstyled(browser.render(width:120,height:25,theme:TerminalTheme())).contains("Lines 18-34/100"))
    _ = browser.handle(.end,width:120,height:25)
    _ = browser.handle(.mouse(button:65,column:90,row:12,released:false),width:120,height:25)
    #expect(unstyled(browser.render(width:120,height:25,theme:TerminalTheme())).contains("Lines 84-100/100"))
    _ = browser.handle(.mouse(button:0,column:20,row:23,released:false),width:120,height:25)
    #expect(unstyled(browser.render(width:120,height:25,theme:TerminalTheme())).contains("Lines 1-17/100"))
    // Wheel over the tree must not scroll the file behind it.
    _ = browser.handle(.mouse(button:65,column:10,row:12,released:false),width:120,height:25)
    #expect(unstyled(browser.render(width:120,height:25,theme:TerminalTheme())).contains("Lines 1-17/100"))
}
@Test func codePanShowsTheLastCharacterAndDraftScrollingDoesNotSave() throws {
    var browser = WorkspaceUI(module:"demo/web")
    let source = String(repeating:"a",count:150)+"Z\n"+(0..<60).map { "// row \($0)" }.joined(separator:"\n")
    browser.finish(text:try scrollFixture(source),status:0)
    _ = browser.handle(.mouse(button:67,column:90,row:12,released:false),width:120,height:25)
    for _ in 0..<30 { _ = browser.handle(.right,width:120,height:25) }
    #expect(unstyled(browser.render(width:120,height:25,theme:TerminalTheme())).contains("Z"))
    _ = browser.handle(.text("e"),width:120,height:25)
    #expect(browser.handle(.pageDown,width:120,height:25) == nil)
    #expect(unstyled(browser.render(width:120,height:25,theme:TerminalTheme())).contains("Lines 18-34/61"))
    _ = browser.handle(.escape,width:120,height:25); _ = browser.handle(.down,width:120,height:25)
    #expect(browser.handle(.enter,width:120,height:25) == nil)
    #expect(unstyled(browser.render(width:120,height:25,theme:TerminalTheme())).contains("Lines 1-17/61"))
}
@Test func refactorButtonOffersComponentsAndPerFunctionFilesWithCancelInitiallySelected() throws {
    var browser = WorkspaceUI(module:"demo/web")
    browser.finish(text:try scrollFixture("import Foundation\n"),status:0)
    #expect(unstyled(browser.render(width:120,height:25,theme:TerminalTheme())).contains("[R Refactor]"))
    _ = browser.handle(.mouse(button:0,column:110,row:4,released:false),width:120,height:25)
    let menu = unstyled(browser.render(width:120,height:25,theme:TerminalTheme()))
    #expect(menu.contains("Split into smaller components")); #expect(menu.contains("One function per file"))
    #expect(browser.handle(.enter,width:120,height:25) == nil)
    _ = browser.handle(.text("r"),width:120,height:25); _ = browser.handle(.up,width:120,height:25)
    #expect(browser.handle(.enter,width:120,height:25) == "'web' 'refactor' 'demo/web' 'App.swift' 'shown-source-hash' 'functions'")
    browser.finish(text:"Provider HTTP 429: capacity full",status:1)
    #expect(unstyled(browser.render(width:120,height:25,theme:TerminalTheme())).contains("Provider HTTP 429"))
    var old = WorkspaceUI(module:"demo/web",change:"old-version")
    old.finish(text:try scrollFixture("import Foundation",readOnly:true),status:0)
    #expect(!unstyled(old.render(width:120,height:25,theme:TerminalTheme())).contains("[R Refactor]"))
    #expect(old.handle(.text("r"),width:120,height:25) == nil)
}
private func refactorCall(_ name: String, _ args: [String:String]) throws -> AIToolCall {
    let arguments = String(decoding:try JSONEncoder().encode(args),as:UTF8.self)
    let object: [String:Any] = ["id":"refactor-call","type":"function","function":["name":name,"arguments":arguments]]
    return try JSONDecoder().decode(AIToolCall.self,from:JSONSerialization.data(withJSONObject:object))
}
@Test func refactorTurnAllowsBoundedAtomicWritesAndRejectsUnrelatedOperationTools() async throws {
    let config = AIConfiguration(baseURL:"http://127.0.0.1:11434",model:"fixture",secret:"",provider:.ollama)
    let module = ModuleSnapshot(application:"demo",name:"web",version:"1",state:"running",pid:42)
    let args = ["module":"demo/web","edits":String(repeating:"x",count:6000)]
    let writer = KilnAssistant { _,_,messages,tools in
        #expect(!tools.contains { $0.function.name == "request_operation" })
        return AIMessage(role:"assistant",content:nil,tool_calls:[try refactorCall("update_web_source",args)])
    }
    let result = try await writer.ask("refactor",session:"refactor",configuration:config,key:"",modules:[module],context:"",knowledge:nil,webChange:{ _,edits in
        #expect(edits.count == 6000); return "Published refactor receipt"
    },webOnly:true) { _,_ in Issue.record("Unexpected read"); return "" }
    #expect(result == "Published refactor receipt")
    let malicious = KilnAssistant { _,_,messages,_ in
        if messages.last?.role == "tool" { return AIMessage(role:"assistant",content:"done") }
        return AIMessage(role:"assistant",content:nil,tool_calls:[try refactorCall("request_operation",["module":"demo/web","operation":"stop"])])
    }
    _ = try await malicious.ask("refactor",session:"refactor",configuration:config,key:"",modules:[module],context:"",knowledge:nil,webChange:{ _,_ in Issue.record("Unrelated write"); return "" },webOnly:true) { _,_ in "" }
    #expect(await malicious.pendingProposals(session:"refactor").isEmpty)
}
@Test func ordinaryAIWritesKeepTheirSmallArgumentLimit() async throws {
    let config = AIConfiguration(baseURL:"http://127.0.0.1:11434",model:"fixture",secret:"",provider:.ollama)
    let module = ModuleSnapshot(application:"demo",name:"web",version:"1",state:"running",pid:42)
    let assistant = KilnAssistant { _,_,messages,_ in
        if messages.last?.role == "tool" { return AIMessage(role:"assistant",content:"rejected") }
        return AIMessage(role:"assistant",content:nil,tool_calls:[try refactorCall("update_web_source",["module":"demo/web","edits":String(repeating:"x",count:6000)])])
    }
    _ = try await assistant.ask("edit",session:"normal",configuration:config,key:"",modules:[module],context:"",knowledge:nil,webChange:{ _,_ in Issue.record("Ordinary tool exceeded its argument grant"); return "" }) { _,_ in "" }
}
