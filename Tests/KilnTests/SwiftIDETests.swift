import Foundation
import Testing
import KilnKit
@testable import KilnDevelopment
@testable import KilnTerminal
@testable import KilnCommands

@Test func sourceKitUsesTheRegisteredSDKForCompletionsDefinitionsAndDraftBuildErrors() async throws {
    guard let sdkPath = ProcessInfo.processInfo.environment["KILN_SWIFT_IDE_SDK"], WebIsolation.supported else { return }
    let base = URL(fileURLWithPath:WebIsolation.canonical(FileManager.default.temporaryDirectory.path)).appendingPathComponent("kiln-ide-test-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    defer { try? FileManager.default.removeItem(at:base) }
    let sourceRoot = base.appendingPathComponent("source")
    let app = "import Foundation\nimport KilnWeb\nfunc run() { let value = Probe(); print(value.greet()) }\n@main struct App { static func main() { run() } }\n"
    let model = "struct Probe { func greet() -> String { \"hello\" } }\n"
    let snapshot = WebFiles(files:["App.swift":Data(app.utf8),"Models/Probe.swift":Data(model.utf8)])
    try snapshot.writeSources(at:sourceRoot)
    let config = WebProjectConfiguration(schemaVersion:1,module:"ide/test",source:sourceRoot.appendingPathComponent("App.swift").path,sdk:sdkPath,publicOrigin:"http://127.0.0.1:18085",ingressPort:18085,workerPorts:[18084,18086],autoPublish:true,root:sourceRoot.path)
    let target = ApplicationManifest(application:"ide",name:"test",version:"initial",executable:"/usr/bin/false",healthURL:"http://127.0.0.1:18084/health",ingressPort:18085)
    let dev = WebDevelopment(directory:base)
    _ = try await dev.register(data:JSONEncoder().encode(config),target:target)
    let messy = app+"\nfunc messy(){let number=1;print(number)}\n"
    let formatted = try await dev.ide(module:"ide/test",request:SwiftIDERequest(action:"format",path:"App.swift",sha256:WebIsolation.digest(Data(app.utf8)),text:messy,cursor:0))
    #expect(formatted.renameFiles?["App.swift"]?.text.contains("func messy() {") == true)
    #expect(formatted.renameFiles?["App.swift"]?.source == app)
    let warning = app+"\nfunc warning() { var neverMutated = 1; print(neverMutated) }\n"
    let fixCursor = warning.distance(from:warning.startIndex,to:warning.range(of:"var neverMutated")!.lowerBound)
    let warningReport = try await dev.ide(module:"ide/test",request:SwiftIDERequest(action:"diagnostics",path:"App.swift",sha256:WebIsolation.digest(Data(app.utf8)),text:warning,cursor:fixCursor))
    #expect(warningReport.locations.contains { $0.message.contains("neverMutated") })
    let actions = try await dev.ide(module:"ide/test",request:SwiftIDERequest(action:"codeActions",path:"App.swift",sha256:WebIsolation.digest(Data(app.utf8)),text:warning,cursor:fixCursor))
    #expect(actions.codeActions?.contains { $0.files?["App.swift"]?.text.contains("let neverMutated") == true } == true)
    #expect(try WebFiles.read(config) == snapshot)
    let incomplete = app.replacingOccurrences(of:"value.greet()",with:"value.gr")
    let caret = incomplete.distance(from:incomplete.startIndex,to:incomplete.range(of:"value.gr")!.upperBound)
    let hash = WebIsolation.digest(Data(app.utf8))
    let completion = try await dev.ide(module:"ide/test",request:SwiftIDERequest(action:"complete",path:"App.swift",sha256:hash,text:incomplete,cursor:caret))
    #expect(completion.completions.contains { $0.label.contains("greet") })
    let definitionCaret = app.distance(from:app.startIndex,to:app.range(of:"Probe()")!.lowerBound)+1
    let definition = try await dev.ide(module:"ide/test",request:SwiftIDERequest(action:"definition",path:"App.swift",sha256:hash,text:app,cursor:definitionCaret))
    #expect(definition.locations.first?.path == "Models/Probe.swift")
    #expect(completion.sessionID != nil && completion.sessionID == definition.sessionID)
    #expect(definition.documentVersion == (completion.documentVersion ?? 0)+1)
    let diagnostics = try await dev.ide(module:"ide/test",request:SwiftIDERequest(action:"diagnostics",path:"App.swift",sha256:hash,text:app+"\nNOT_SWIFT\n",cursor:0))
    #expect(diagnostics.locations.contains { $0.message.hasPrefix("error:") })
    #expect(diagnostics.sessionID == definition.sessionID)
    let localCaret = app.distance(from:app.startIndex,to:app.range(of:"value =")!.lowerBound)+1
    let references = try await dev.ide(module:"ide/test",request:SwiftIDERequest(action:"references",path:"App.swift",sha256:hash,text:app,cursor:localCaret))
    #expect(references.locations.filter { $0.path == "App.swift" }.count >= 2)
    let renamed = try await dev.ide(module:"ide/test",request:SwiftIDERequest(action:"rename",path:"App.swift",sha256:hash,text:app,cursor:localCaret,newName:"renamedValue"))
    #expect(renamed.renameFiles?["App.swift"]?.text.contains("let renamedValue =") == true)
    #expect(renamed.renameFiles?["App.swift"]?.text.contains("renamedValue.greet()") == true)
    let projectReferences = try await dev.ide(module:"ide/test",request:SwiftIDERequest(action:"references",path:"App.swift",sha256:hash,text:app,cursor:definitionCaret))
    #expect(Set(projectReferences.locations.map(\.path)) == ["App.swift","Models/Probe.swift"])
    #expect(!projectReferences.message.contains("Document references only"))
    let projectRename = try await dev.ide(module:"ide/test",request:SwiftIDERequest(action:"rename",path:"App.swift",sha256:hash,text:app,cursor:definitionCaret,newName:"Device"))
    #expect(projectRename.renameFiles?["App.swift"]?.text.contains("Device()") == true)
    #expect(projectRename.renameFiles?["Models/Probe.swift"]?.text.contains("struct Device") == true)
    #expect(try WebFiles.read(config) == snapshot)
    let isolated = try await dev.ide(module:"ide/test",request:SwiftIDERequest(action:"definition",path:"App.swift",sha256:hash,text:app,cursor:definitionCaret),scope:"other-editor")
    #expect(isolated.sessionID != definition.sessionID)
    let back = try await dev.ide(module:"ide/test",request:SwiftIDERequest(action:"definition",path:"App.swift",sha256:hash,text:app,cursor:definitionCaret))
    #expect(back.sessionID == definition.sessionID)
    let sessions = await dev.languageSessions
    let localKey = WebIsolation.digest(Data("local-console\nide/test".utf8))
    let session = try #require(sessions[localKey])
    await session.service.stop()
    let restarted = try await dev.ide(module:"ide/test",request:SwiftIDERequest(action:"definition",path:"App.swift",sha256:hash,text:app,cursor:definitionCaret))
    #expect(restarted.sessionID != definition.sessionID)
    #expect(restarted.locations.first?.path == "Models/Probe.swift")
    let cancelled = Task { try await dev.ide(module:"ide/test",request:SwiftIDERequest(action:"definition",path:"App.swift",sha256:hash,text:app,cursor:definitionCaret)) }
    cancelled.cancel()
    do { _ = try await cancelled.value; Issue.record("Cancelled language request returned a stale result") } catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
    let recovered = try await dev.ide(module:"ide/test",request:SwiftIDERequest(action:"definition",path:"App.swift",sha256:hash,text:app,cursor:definitionCaret))
    #expect(recovered.locations.first?.path == "Models/Probe.swift")
    let annotation = app+"\nfunc annotation(_ value: Probe) {}\n"
    let annotationCursor = annotation.distance(from:annotation.startIndex,to:annotation.range(of:"Probe)")!.lowerBound)+1
    let annotated = try await dev.ide(module:"ide/test",request:SwiftIDERequest(action:"definition",path:"App.swift",sha256:hash,text:annotation,cursor:annotationCursor))
    #expect(annotated.locations.first?.path == "Models/Probe.swift")

    let exampleURL = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/ExampleWeb/Web.swift")
    let full = try String(contentsOf:exampleURL,encoding:.utf8)+"\nfunc annotation(_ value: Probe) {}\n"
    let fullCursor = full.distance(from:full.startIndex,to:full.range(of:"Probe)")!.lowerBound)+1
    let fullDefinition = try await dev.ide(module:"ide/test",request:SwiftIDERequest(action:"definition",path:"App.swift",sha256:hash,text:full,cursor:fullCursor))
    #expect(fullDefinition.locations.first?.path == "Models/Probe.swift")
    let valid = try await dev.ide(module:"ide/test",request:SwiftIDERequest(action:"build",path:"App.swift",sha256:hash,text:app,cursor:0))
    #expect(valid.message.contains("Build passed"))
    let invalid = try await dev.ide(module:"ide/test",request:SwiftIDERequest(action:"build",path:"App.swift",sha256:hash,text:app+"\nNOT_SWIFT\n",cursor:0))
    #expect(invalid.message.contains("Build failed")); #expect(invalid.locations.contains { $0.path == "App.swift" && $0.line >= 4 })
    let otherDraft = SwiftIDEBuffer(sha256:WebIsolation.digest(Data(model.utf8)),text:model+"\nNOT_SWIFT\n")
    let allBuffers = try await dev.ide(module:"ide/test",request:SwiftIDERequest(action:"build",path:"App.swift",sha256:hash,text:app,cursor:0,buffers:["Models/Probe.swift":otherDraft]))
    #expect(allBuffers.message.contains("Build failed"))
    #expect(allBuffers.locations.contains { $0.path == "Models/Probe.swift" })
    #expect(try WebFiles.read(config) == snapshot)
    await #expect(throws:(any Error).self) { _ = try await dev.ide(module:"ide/test",request:SwiftIDERequest(action:"complete",path:"../outside.swift",sha256:hash,text:app,cursor:0)) }
}

@Test func swiftDefinitionUsesTheClickedSourceCaretAfterHorizontalAndVerticalScrolling() throws {
    // Pure terminal coordinate check: no synthetic token search is used by navigation.
    let lines = (1...76).map { "// line \($0)" }+["func ideDefinitionProbe(_ value: JumpTarget) {}", ""]
    let text = lines.joined(separator:"\n")
    let object: [String:Any] = ["tree":["version":"workspace","editable":true,"projectRoot":true,"files":[["path":"App.swift","sha256":"hash","bytes":text.count]]],"file":["file":"App.swift","sha256":"hash","source":text,"version":"workspace"]]
    var ui = WorkspaceUI(module:"test/web")
    ui.finish(text:String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self),status:0)
    _ = ui.handle(.end,width:90,height:45)
    let col = 34+lines[76].distance(from:lines[76].startIndex,to:lines[76].range(of:"JumpTarget")!.lowerBound)+1
    _ = ui.handle(.mouse(button:0,column:col,row:40,released:false),width:90,height:45)
    let effect = ui.handle(.definition,width:90,height:45)
    let command = try #require(effect)
    let parts = try KilnCommands.tokenize(command)
    let query = try JSONDecoder().decode(SwiftIDERequest.self,from:Data(parts[3].utf8))
    #expect(String(query.text.prefix(query.cursor)).hasSuffix("J"))
}
