import Foundation
import Testing
import KilnKit
@testable import KilnDevelopment
@testable import KilnTerminal
@testable import KilnCommands

@Test func swiftTestDiscoveryExecutionFilteringAndIsolationUseTheRegisteredSDK() async throws {
    guard let sdk = ProcessInfo.processInfo.environment["KILN_SWIFT_TEST_SDK"], WebIsolation.supported else { return }
    let root = URL(fileURLWithPath:WebIsolation.canonical(FileManager.default.temporaryDirectory.path)).appendingPathComponent("kiln-test-navigation-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let source = root.appendingPathComponent("source"), secret = root.appendingPathComponent("secret.txt")
    let app = "@main struct App { static func main() { fatalError(\"Application entry point must not execute\") } }\n"
    let tests = """
    import Foundation
    import Testing
    @testable import KilnApplication
    @Test func passes() { #expect(Probe.value == 7) }
    @Test func fails() { #expect(Probe.value == 99) }
    @Test(.disabled("fixture")) func skipped() { #expect(false) }
    @Test func isolation() throws {
        #expect((try? String(contentsOfFile: "\(secret.path)", encoding: .utf8)) == nil)
        #expect((try? "changed".write(toFile: "\(secret.path)", atomically: false, encoding: .utf8)) == nil)
        #expect(ProcessInfo.processInfo.environment["KILN_TEST_SECRET"] == nil)
    }
    """
    let snapshot = WebFiles(files:["App.swift":Data(app.utf8),"Models/Probe.swift":Data("struct Probe { static let value = 7 }\n".utf8),"Tests/ProbeTests.swift":Data(tests.utf8)])
    try snapshot.writeSources(at:source); try KilnStateFile.write(Data("private fixture".utf8),to:secret)
    let config = WebProjectConfiguration(schemaVersion:1,module:"test/site",source:source.appendingPathComponent("App.swift").path,sdk:sdk,publicOrigin:"http://127.0.0.1:18085",ingressPort:18085,workerPorts:[18084,18086],autoPublish:true,root:source.path)
    let target = ApplicationManifest(application:"test",name:"site",version:"initial",executable:"/usr/bin/false",healthURL:"http://127.0.0.1:18084/health",ingressPort:18085)
    let dev = WebDevelopment(directory:root.appendingPathComponent("development"))
    _ = try await dev.register(data:JSONEncoder().encode(config),target:target)
    func request(_ action: String) -> SwiftIDERequest { SwiftIDERequest(action:action,path:"App.swift",sha256:WebIsolation.digest(Data(app.utf8)),text:app,cursor:0) }
    let listed = try await dev.ide(module:"test/site",request:request("testList"))
    #expect(listed.tests?.count == 4, Comment(rawValue:listed.message))
    #expect(listed.tests?.allSatisfy({$0.state == "discovered"}) == true)
    let run = try await dev.ide(module:"test/site",request:request("test"))
    #expect(run.tests?.filter({$0.state == "failed"}).count == 1, Comment(rawValue:run.message))
    #expect(run.tests?.filter({$0.state == "passed"}).count == 2)
    #expect(run.tests?.filter({$0.state == "skipped"}).count == 1)
    #expect(run.locations.first?.path == "Tests/ProbeTests.swift")
    #expect(run.locations.first?.message.contains("Expectation failed") == true)
    var single = request("test"); single.testFilter = try #require(listed.tests?.first(where:{$0.name == "passes()"})?.id)
    let filtered = try await dev.ide(module:"test/site",request:single)
    #expect(filtered.tests?.filter({$0.state == "passed"}).count == 1)
    #expect(filtered.tests?.contains(where:{$0.state == "failed"}) == false)
    let build = try await dev.ide(module:"test/site",request:request("build"))
    #expect(build.message.hasPrefix("Build passed"), Comment(rawValue:build.message))
    #expect(try WebFiles.read(config) == snapshot)
    #expect(try String(contentsOf:secret,encoding:.utf8) == "private fixture")
    let editorText = "import Testing\n@testable import KilnApplication\nfunc editorProbe() { _ = Probe.va }\n"
    let caret = editorText.distance(from:editorText.startIndex,to:editorText.range(of:"Probe.va")!.upperBound)
    let completion = try await dev.ide(module:"test/site",request:SwiftIDERequest(action:"complete",path:"Tests/ProbeTests.swift",sha256:WebIsolation.digest(Data(tests.utf8)),text:editorText,cursor:caret))
    #expect(completion.completions.contains(where:{$0.label.contains("value")}),Comment(rawValue:completion.message))
    let invalidTest = "import Testing\n@testable import KilnApplication\nlet compilerError: Int = \"wrong\"\n"
    let diagnostic = try await dev.ide(module:"test/site",request:SwiftIDERequest(action:"diagnostics",path:"Tests/ProbeTests.swift",sha256:WebIsolation.digest(Data(tests.utf8)),text:invalidTest,cursor:0))
    #expect(diagnostic.locations.contains(where:{$0.path == "Tests/ProbeTests.swift" && $0.message.hasPrefix("error:")}),Comment(rawValue:diagnostic.message))
    let progress = SwiftTestProgressRecorder()
    let slow = "import Testing\n@testable import KilnApplication\n@Test func slow() async throws { try await Task.sleep(for: .seconds(30)) }\n"
    let slowRequest = SwiftIDERequest(action:"test",path:"Tests/ProbeTests.swift",sha256:WebIsolation.digest(Data(tests.utf8)),text:slow,cursor:0)
    let work = Task { try await dev.ide(module:"test/site",request:slowRequest,progress:{ progress.record($0) }) }
    for _ in 0..<600 {
        if progress.contains("1 running") { break }
        try await Task.sleep(for:.milliseconds(50))
    }
    #expect(progress.contains("1 running"), "Test execution must start before cancellation")
    work.cancel()
    do { _ = try await work.value; Issue.record("Cancelled tests returned a completed result") } catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
    let recovered = try await dev.ide(module:"test/site",request:single)
    #expect(recovered.tests?.filter({$0.state == "passed"}).count == 1)
    #expect(try WebFiles.read(config) == snapshot)
    // A runner that cannot load its test runtime must not report zero tests as
    // successful discovery. Retain a visible incomplete outcome and console reason.
    var blockedSDK = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:sdk))) as! [String:Any]
    blockedSDK["testReadRoots"] = [String]()
    blockedSDK["runtimeLibraries"] = [String]()
    let blockedFile = root.appendingPathComponent("blocked-sdk.json")
    try KilnStateFile.write(JSONSerialization.data(withJSONObject:blockedSDK),to:blockedFile)
    var blockedConfig = try JSONSerialization.jsonObject(with:JSONEncoder().encode(config)) as! [String:Any]
    blockedConfig["sdk"] = blockedFile.path
    let blocked = WebDevelopment(directory:root.appendingPathComponent("blocked"))
    _ = try await blocked.register(data:JSONSerialization.data(withJSONObject:blockedConfig),target:target)
    let unavailable = try await blocked.ide(module:"test/site",request:request("testList"))
    #expect(unavailable.message.hasPrefix("Test run incomplete"),Comment(rawValue:unavailable.message))
    #expect(try WebFiles.read(config) == snapshot)
    print("KILN_SWIFT_TEST_NAVIGATOR_COMPLETE")
}

@Test func testEventsKeepFailuresKnownIssuesAndUnsafeLocationsSeparate() throws {
    let location: [String:Any] = ["fileID":"Tests/Probe.swift","line":4,"column":9]
    func record(_ kind: String, _ payload: [String:Any]) throws -> Data { try JSONSerialization.data(withJSONObject:["version":0,"kind":kind,"payload":payload])+Data([10]) }
    var data = try record("test",["id":"one","kind":"function","name":"one()","sourceLocation":location])
    data += try record("event",["kind":"runStarted"])
    data += try record("event",["kind":"testStarted","testID":"one"])
    data += try record("event",["kind":"issueRecorded","testID":"one","issue":["isKnown":true,"sourceLocation":location]])
    data += try record("event",["kind":"issueRecorded","testID":"one","issue":["isKnown":false,"sourceLocation":location],"messages":[["text":"first failure"]]])
    data += try record("event",["kind":"issueRecorded","testID":"one","issue":["isKnown":false,"sourceLocation":location],"messages":[["text":"second failure"]]])
    data += try record("event",["kind":"testEnded","testID":"one"])
    data += try record("event",["kind":"futureEvent"])
    data += Data("{\"kind\":".utf8) // An unfinished live record is parsed after the next chunk.
    let result = try SwiftTestEvents(data:data,files:["Tests/Probe.swift"],sourceRoot:URL(fileURLWithPath:"/private/job/Sources"))
    #expect(result.tests.first?.state == "failed")
    #expect(result.tests.first?.failures.count == 2)
    #expect(result.tests.first?.location?.path == "Tests/Probe.swift")
    #expect(!result.ended)
    let escaped = try record("test",["id":"outside","kind":"function","name":"outside()","sourceLocation":["fileID":"Tests/Missing.swift","_filePath":"/private/elsewhere/Probe.swift","line":1,"column":1]])
    #expect(try SwiftTestEvents(data:escaped,files:["Tests/Probe.swift"],sourceRoot:URL(fileURLWithPath:"/private/job/Sources")).tests.first?.location == nil)
    #expect(throws:(any Error).self) { try SwiftTestEvents(data:Data("bad\n".utf8),files:[],sourceRoot:URL(fileURLWithPath:"/job")) }
    #expect(throws:(any Error).self) { try SwiftTestEvents(data:Data("{\"version\":99}\n".utf8),files:[],sourceRoot:URL(fileURLWithPath:"/job")) }
}

private func testNavigatorEditor() throws -> WorkspaceUI {
    let app = "@main struct App { static func main() {} }\n"
    let object: [String:Any] = ["tree":["version":"workspace","editable":true,"projectRoot":true,"files":[["path":"App.swift","sha256":"a","bytes":app.count],["path":"Tests/Probe.swift","sha256":"b","bytes":20]]],"file":["file":"App.swift","sha256":"a","source":app,"version":"workspace"]]
    var ui = WorkspaceUI(module:"demo/web")
    ui.finish(text:String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self),status:0); return ui
}
@Test func testNavigatorRetainsResultsJumpsToFailuresAndRerunsCurrentDrafts() throws {
    var ui = try testNavigatorEditor()
    let discover = ui.handle(.tests,width:140,height:35)
    #expect(discover?.contains("testList") == true)
    ui.languageProgress("Discovering Swift tests")
    #expect(ui.render(width:140,height:35,theme:TerminalTheme()).contains("Discovering Swift tests"))
    let failure = SwiftIDELocation(path:"Tests/Probe.swift",line:7,column:4,message:"Expectation failed")
    var result = SwiftIDEResult(action:"test",message:"Tests finished: 1 failed")
    result.tests = [SwiftIDETest(id:"Probe/fails()",name:"fails()",state:"failed",location:failure,failures:[failure])]; result.locations = [failure]
    ui.finish(text:String(decoding:try JSONEncoder().encode(result),as:UTF8.self),status:0)
    #expect(ui.render(width:140,height:35,theme:TerminalTheme()).contains("[failed] fails()"))
    let open = ui.handle(.enter,width:140,height:35)
    #expect(open == "'web' 'file' 'demo/web' 'Tests/Probe.swift'")
    ui.finish(text:"{\"file\":\"Tests/Probe.swift\",\"sha256\":\"b\",\"source\":\"import Testing\\n// fixture\\n\",\"version\":\"workspace\"}",status:0)
    _ = ui.handle(.text("e"),width:140,height:35); _ = ui.handle(.text("// new draft\n"),width:140,height:35)
    _ = ui.handle(.tests,width:140,height:35)
    #expect(ui.render(width:140,height:35,theme:TerminalTheme()).contains("last snapshot"))
    _ = ui.handle(.text("f"),width:140,height:35)
    #expect(ui.render(width:140,height:35,theme:TerminalTheme()).contains("Tests/Probe.swift:7:4"))
    _ = ui.handle(.text("f"),width:140,height:35)
    let selected = ui.handle(.text("r"),width:140,height:35)
    let args = try KilnCommands.tokenize(try #require(selected))
    let request = try JSONDecoder().decode(SwiftIDERequest.self,from:Data(args[3].utf8))
    #expect(request.action == "test" && request.testFilter == "Probe/fails()")
    #expect(request.text.contains("new draft"))
    #expect(ui.hasUnsavedEdits)
    ui.cancelLanguageRead()
    #expect(ui.render(width:140,height:35,theme:TerminalTheme()).contains("Cancelling"))
    var decoder = TerminalKeys()
    #expect(decoder.feed(Array("\u{1b}OP\u{1b}[11~".utf8)) == [.tests,.tests])
}

private final class SwiftTestProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func contains(_ value: String) -> Bool { lock.lock(); defer { lock.unlock() }; return values.contains(where:{$0.contains(value)}) }
}

@Test func dismissedCompletionCannotReopenFromAQueuedLateReplyOrBlockDiscard() throws {
    var ui = try testNavigatorEditor()
    _ = ui.handle(.text("e"),width:140,height:35)
    _ = ui.handle(.text("word"),width:140,height:35)
    #expect(ui.completeAfterTyping() != nil)
    _ = ui.handle(.complete,width:140,height:35) // Explicit request arrives while automatic completion is pending.
    var reply = SwiftIDEResult(action:"complete",message:"Completions")
    reply.completions = [SwiftIDECompletion(label:"candidate",detail:"fixture",text:"candidate",start:0,end:4)]
    ui.finish(text:String(decoding:try JSONEncoder().encode(reply),as:UTF8.self),status:0)
    #expect(ui.takeDeferredLanguageRead() != nil)
    _ = ui.handle(.escape,width:140,height:35)
    ui.finish(text:String(decoding:try JSONEncoder().encode(reply),as:UTF8.self),status:0)
    #expect(!ui.render(width:140,height:35,theme:TerminalTheme()).contains("Suggestions:"))
    _ = ui.handle(.escape,width:140,height:35)
    #expect(ui.render(width:140,height:35,theme:TerminalTheme()).contains("Discard unsaved edits?"))
    #expect(ui.hasUnsavedEdits)
}

@Test(arguments:[false,true]) func escapeCancelsQueuedIntentAndDiscardWhileDismissedCompletionIsPending(publish: Bool) throws {
    var ui = try testNavigatorEditor()
    _ = ui.handle(.text("e"),width:140,height:35); _ = ui.handle(.text("word"),width:140,height:35)
    #expect(ui.completeAfterTyping() != nil)
    _ = ui.handle(publish ? .eof : .build,width:140,height:35)
    _ = ui.handle(.escape,width:140,height:35)
    _ = ui.handle(.escape,width:140,height:35)
    #expect(ui.render(width:140,height:35,theme:TerminalTheme()).contains("Discard unsaved edits?"))
    _ = ui.handle(.escape,width:140,height:35)
    #expect(!ui.render(width:140,height:35,theme:TerminalTheme()).contains("Discard unsaved edits?"))
    ui.finish(text:String(decoding:try JSONEncoder().encode(SwiftIDEResult(action:"complete",message:"Late completion")),as:UTF8.self),status:0)
    #expect(ui.takeDeferredLanguageRead() == nil)
    #expect(!ui.render(width:140,height:35,theme:TerminalTheme()).contains("Compile and publish"))
    #expect(ui.hasUnsavedEdits)
}

@Test func escapingPendingCompletionReturnsVimToNormalWithoutDiscardingDrafts() throws {
    var ui = try testNavigatorEditor()
    _ = ui.handle(.vim,width:140,height:35)
    _ = ui.handle(.text("i"),width:140,height:35)
    _ = ui.handle(.text("word"),width:140,height:35)
    #expect(ui.completeAfterTyping() != nil)
    _ = ui.handle(.escape,width:140,height:35)
    #expect(ui.render(width:140,height:35,theme:TerminalTheme()).contains("Vim NORMAL"))
    _ = ui.handle(.escape,width:140,height:35)
    #expect(!ui.render(width:140,height:35,theme:TerminalTheme()).contains("Discard unsaved edits?"))
    ui.finish(text:String(decoding:try JSONEncoder().encode(SwiftIDEResult(action:"complete",message:"Late completion")),as:UTF8.self),status:0)
    #expect(ui.hasUnsavedEdits)
    #expect(ui.render(width:140,height:35,theme:TerminalTheme()).contains("Vim NORMAL"))
}
