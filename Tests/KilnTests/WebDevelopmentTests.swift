import Foundation
import Testing
import KilnKit
@testable import KilnAI
import KilnRuntime
@testable import KilnDevelopment
@testable import KilnCommands

private func webDevRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return url
}
private func webDevFixture(_ root: URL, auto: Bool = true) throws -> (Data, ApplicationManifest) {
    let source = root.appendingPathComponent("App.swift"), sdk = root.appendingPathComponent("sdk.json")
    try KilnStateFile.write(Data("original heading".utf8), to: source)
    let input = root.appendingPathComponent("object")
    try KilnStateFile.write(Data("trusted object".utf8), to: input)
    let recipe: [String: Any] = ["schemaVersion":1, "compiler":"/usr/bin/false", "builder":"/usr/bin/false", "launcher":"/usr/bin/false", "arguments":[], "objects":[input.path], "readRoots":[root.path], "runtimeLibraries":[], "inputDigests":[input.path: WebIsolation.digest(try Data(contentsOf: input))]]
    try KilnStateFile.write(JSONSerialization.data(withJSONObject: recipe), to: sdk)
    let config: [String: Any] = ["schemaVersion":1, "module":"demo/web", "source":source.path, "sdk":sdk.path, "publicOrigin":"http://127.0.0.1:18085", "ingressPort":18085, "workerPorts":[18084,18086], "autoPublish":auto]
    let target = ApplicationManifest(application: "demo", name: "web", version: "1", executable: "/usr/bin/false", healthURL: "http://127.0.0.1:18084/health", ingressPort: 18085)
    return (try JSONSerialization.data(withJSONObject: config), target)
}
@Test func developmentSourceIsScopedAndFailedBuildNeverPublishesOrChangesSource() async throws {
    let root = try webDevRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (config, target) = try webDevFixture(root), dev = WebDevelopment(directory: root)
    if !WebIsolation.supported {
        await #expect(throws: (any Error).self) { _ = try await dev.register(data: config, target: target) }
        return
    }
    #expect(try await dev.register(data: config, target: target).contains("Auto-publish: true"))
    #expect(try await dev.inventory().contains("demo/web"))
    #expect(try await dev.source(module: "demo/web", offset: 0).contains("original heading"))
    await #expect(throws: (any Error).self) { _ = try await dev.source(module: "elsewhere/web", offset: 0) }
    await #expect(throws: (any Error).self) { _ = try await dev.source(module: "demo/web", offset: -1) }
    do {
        _ = try await dev.change(module: "demo/web", owner: "admin", edits: "[{\"before\":\"original\",\"after\":\"edited\"}]", target: target, progress: { _ in }, validate: {}, deploy: { _ in Issue.record("Failed build reached deployment"); return "bad" })
        Issue.record("Failed build reported success")
    } catch { #expect(String(describing: error).contains("before deployment")) }
    #expect(try String(contentsOf: root.appendingPathComponent("App.swift"), encoding: .utf8) == "original heading")
    #expect(try await dev.changes(module: "demo/web").contains("failed"))
    let restarted = WebDevelopment(directory: root)
    #expect(try await restarted.inventory().contains("demo/web"))
    #expect(try await restarted.changes(module: "demo/web").contains("failed"))
}
@Test func developmentGrantRejectsUnmatchedEditsMissingOptInAndChangedSdk() async throws {
    guard WebIsolation.supported else { return }
    let root = try webDevRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (config, target) = try webDevFixture(root), dev = WebDevelopment(directory: root)
    _ = try await dev.register(data: config, target: target)
    for edits in ["[]", "[{\"before\":\"missing\",\"after\":\"x\"}]", "[{\"before\":\"\",\"after\":\"x\"}]"] {
        await #expect(throws: (any Error).self) { _ = try await dev.change(module: "demo/web", owner: "admin", edits: edits, target: target, progress: { _ in }, validate: {}, deploy: { _ in Issue.record("Invalid edit published"); return "bad" }) }
    }
    try KilnStateFile.write(Data("different SDK".utf8), to: root.appendingPathComponent("object"))
    await #expect(throws: (any Error).self) { _ = try await dev.change(module: "demo/web", owner: "admin", edits: "[{\"before\":\"original\",\"after\":\"edited\"}]", target: target, progress: { _ in }, validate: {}, deploy: { _ in Issue.record("Changed SDK published"); return "bad" }) }
    let (disabled, _) = try webDevFixture(root, auto: false)
    _ = try await dev.register(data: disabled, target: target)
    await #expect(throws: (any Error).self) { _ = try await dev.change(module: "demo/web", owner: "admin", edits: "[{\"before\":\"original\",\"after\":\"edited\"}]", target: target, progress: { _ in }, validate: {}, deploy: { _ in Issue.record("Missing grant published"); return "bad" }) }
}
@Test func developmentToolsAreAbsentWithoutForegroundGrantAndWriteReceiptIsFinal() async throws {
    let config = AIConfiguration(baseURL: "http://127.0.0.1:11434", model: "fixture", secret: "", provider: .ollama)
    let module = ModuleSnapshot(application: "demo", name: "web", version: "1", state: "running", pid: 42)
    let noGrant = KilnAssistant { _, _, _, tools in
        #expect(!tools.contains { $0.function.name.contains("web_") })
        return AIMessage(role: "assistant", content: "read-only")
    }
    _ = try await noGrant.ask("edit", session: "x", configuration: config, key: "", modules: [module], context: "", knowledge: nil) { _, _ in "" }
    let writer = KilnAssistant { _, _, _, tools in
        #expect(tools.contains { $0.function.name == "update_web_source" })
        let args = String(decoding: try JSONEncoder().encode(["module":"demo/web", "edits":"[]"]), as: UTF8.self)
        let bytes = try JSONSerialization.data(withJSONObject: ["id":"write", "type":"function", "function":["name":"update_web_source", "arguments":args]])
        return AIMessage(role: "assistant", content: nil, tool_calls: [try JSONDecoder().decode(AIToolCall.self, from: bytes), try JSONDecoder().decode(AIToolCall.self, from: bytes)])
    }
    let receipt = try await writer.ask("edit", session: "x", configuration: config, key: "", modules: [module], context: "", knowledge: nil, webChange: { _, _ in "controller receipt" }) { _, _ in "" }
    #expect(receipt == "controller receipt")
}
@Test func retainedCodeIsCompleteScopedAndIntegrityCheckedWithoutReadingWorkspace() async throws {
    guard WebIsolation.supported else { return }
    let root = try webDevRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (config, target) = try webDevFixture(root), dev = WebDevelopment(directory: root)
    _ = try await dev.register(data: config, target: target)
    let id = UUID().uuidString, source = Data("import Foundation\n// unchanged line\nlet heading = \"published\"\n".utf8)
    let job = root.appendingPathComponent("web-development/jobs/" + id)
    try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let file = job.appendingPathComponent("App.swift")
    try KilnStateFile.write(source, to: file)
    let receipt: [String:Any] = ["id":id, "module":"demo/web", "owner":"admin", "before":"unused", "after":WebIsolation.digest(source), "version":"dev-test", "status":"active", "result":"Published", "created":Date().timeIntervalSinceReferenceDate]
    try KilnStateFile.write(JSONSerialization.data(withJSONObject: receipt), to: job.appendingPathComponent("receipt.json"))
    let text = try await dev.code(module: "demo/web", id: id)
    #expect(text.contains("Release dev-test"))
    #expect(text.contains("    1 | import Foundation\n    2 | // unchanged line\n    3 | let heading = \"published\"\n    4 | "))
    #expect(try String(contentsOf: root.appendingPathComponent("App.swift"), encoding: .utf8) == "original heading")
    await #expect(throws: (any Error).self) { _ = try await dev.code(module: "elsewhere/web", id: id) }
    await #expect(throws: (any Error).self) { _ = try await dev.code(module: "demo/web", id: "../../App.swift") }
    try KilnStateFile.write(Data("tampered".utf8), to: file)
    await #expect(throws: (any Error).self) { _ = try await dev.code(module: "demo/web", id: id) }
}
@Test func refactorBindsDisplayedFileAndProjectGrantBeforeAnyAIWrite() async throws {
    guard WebIsolation.supported else { return }
    let root = try webDevRoot(); defer { try? FileManager.default.removeItem(at:root) }
    let (legacy,target) = try webDevFixture(root), dev = WebDevelopment(directory:root)
    _ = try await dev.register(data:legacy,target:target)
    await #expect(throws:(any Error).self) { _ = try await dev.refactor(module:"demo/web",path:"App.swift",sha256:WebIsolation.digest(Data("original heading".utf8)),style:"functions") }
    let sourceRoot = URL(fileURLWithPath:WebIsolation.canonical(root.path)).appendingPathComponent("source")
    let snapshot = WebFiles(files:["App.swift":Data("import Foundation\n".utf8),"Models/Counter.swift":Data("actor Counter {}\n".utf8)])
    try snapshot.writeSources(at:sourceRoot)
    var sdk = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("sdk.json"))) as! [String:Any]; sdk["projectFiles"] = true
    try KilnStateFile.write(JSONSerialization.data(withJSONObject:sdk),to:root.appendingPathComponent("sdk.json"))
    var config = try JSONSerialization.jsonObject(with:legacy) as! [String:Any]; config["root"] = sourceRoot.path; config["source"] = sourceRoot.appendingPathComponent("App.swift").path
    _ = try await dev.register(data:JSONSerialization.data(withJSONObject:config),target:target)
    let hash = WebIsolation.digest(snapshot.files["Models/Counter.swift"]!)
    let request = try await dev.refactor(module:"demo/web",path:"Models/Counter.swift",sha256:hash,style:"functions")
    #expect(request.prompt.contains("extensions of the existing type")); #expect(request.prompt.contains("32 operations"))
    try await dev.verifyRefactor(request,module:"demo/web")
    await #expect(throws:(any Error).self) { try await dev.verifyRefactor(request,module:"elsewhere/web") }
    try KilnStateFile.write(Data("actor Changed {}".utf8),to:sourceRoot.appendingPathComponent("Models/Counter.swift"))
    await #expect(throws:(any Error).self) { try await dev.verifyRefactor(request,module:"demo/web") }
    try snapshot.writeSources(at:sourceRoot)
    config["autoPublish"] = false
    _ = try await dev.register(data:JSONSerialization.data(withJSONObject:config),target:target)
    await #expect(throws:(any Error).self) { try await dev.verifyRefactor(request,module:"demo/web") }
}

private actor EditorPromptCapture {
    var value = ""
    func set(_ text: String) { value = text }
    func get() -> String { value }
}
@Test func editorChatContextResolvesRegisteredFilesAndRejectsEscapesBeforeInference() async throws {
    guard WebIsolation.supported else { return }
    let root = try webDevRoot(); defer { try? FileManager.default.removeItem(at:root) }
    let (config,target) = try webDevFixture(root)
    let runtime = try KilnRuntime(stateDirectory:root.appendingPathComponent("state"))
    let capture = EditorPromptCapture()
    let assistant = KilnAssistant(completion: { _,_,messages,_ in
        await capture.set(messages.last(where: { $0.role == "user" })?.content ?? "")
        return AIMessage(role:"assistant",content:"Inspected current context")
    })
    let commands = KilnCommands(runtime:runtime,assistant:assistant)
    _ = try await commands.webDevelopment.register(data:config,target:target)
    let provider = AIConfiguration(baseURL:"http://127.0.0.1:11434",model:"fixture",secret:"",provider:.ollama)
    try KilnStateFile.write(JSONEncoder().encode(provider),to:root.appendingPathComponent("state/ai.json"))
    func request(path: String, module: String = "demo/web") throws -> String {
        let context = ["module":module,"path":path,"sha256":WebIsolation.digest(Data("original heading".utf8)),"revision":"workspace","unsaved":"false","firstVisibleLine":"1"]
        let json = String(decoding:try JSONEncoder().encode(context),as:UTF8.self)
        return "ai ask --workspace '" + json + "' 'Explain this file'"
    }
    let valid = await commands.execute(try request(path:"App.swift"))
    #expect(valid.status == 0)
    #expect(await capture.get().contains("CURRENT EDITOR CONTEXT"))
    #expect(await capture.get().contains("App.swift"))
    var context = ["module":"demo/web","path":"App.swift","sha256":WebIsolation.digest(Data("original heading".utf8)),"revision":"workspace","unsaved":"false"]
    try await commands.validateEditorWrite(context,module:"demo/web")
    context["unsaved"] = "true"
    await #expect(throws:(any Error).self) { try await commands.validateEditorWrite(context,module:"demo/web") }
    context["unsaved"] = "false"; context["revision"] = "retained-change"
    await #expect(throws:(any Error).self) { try await commands.validateEditorWrite(context,module:"demo/web") }
    context["revision"] = "workspace"; context["sha256"] = String(repeating:"0",count:64)
    await #expect(throws:(any Error).self) { try await commands.validateEditorWrite(context,module:"demo/web") }
    await #expect(throws:(any Error).self) { try await commands.validateEditorWrite(context,module:"other/web") }
    #expect(try String(contentsOf:root.appendingPathComponent("App.swift"),encoding:.utf8) == "original heading")
    #expect(try await commands.webDevelopment.changes(module:"demo/web").isEmpty)
    await capture.set("")
    for (path,module) in [("../outside.swift","demo/web"),("App.swift","other/web"),("Missing.swift","demo/web")] {
        let denied = await commands.execute(try request(path:path,module:module))
        #expect(denied.status != 0)
        #expect(await capture.get().isEmpty)
    }
    await runtime.shutdown()
}
