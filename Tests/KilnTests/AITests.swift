import Foundation
import Testing
import KilnAI
import KilnRuntime
import KilnKit
import KilnTerminal

private actor AISequence {
    var replies: [AIMessage]
    var requests: [[AIMessage]] = []
    var reads = 0
    init(_ replies: [AIMessage]) { self.replies = replies }
    func next(_ messages: [AIMessage]) -> AIMessage { requests.append(messages); return replies.removeFirst() }
    func read() -> String { reads += 1; return "running" }
}
private let aiConfig = AIConfiguration(baseURL: "https://api.erebine.ai/test/v1", model: "test", secret: "test-reference")
private let aiModule = ModuleSnapshot(application: "demo", name: "worker", version: "26.10.07.3", state: "running", pid: 123)
private func call(_ name: String, arguments: String) throws -> AIMessage {
    let object: [String: Any] = ["id": "test-call", "type": "function", "function": ["name": name, "arguments": arguments]]
    let call = try JSONDecoder().decode(AIToolCall.self, from: JSONSerialization.data(withJSONObject: object))
    return AIMessage(role: "assistant", content: nil, tool_calls: [call])
}

@Test func aiCannotAccessUnregisteredToolsOrRunShell() async throws {
    let sequence = AISequence([try call("vault_read", arguments: "{\"name\":\"credential\"}"), AIMessage(role: "assistant", content: "Unavailable")])
    let ai = KilnAssistant { _, _, messages, _ in await sequence.next(messages) }
    let result = try await ai.ask("Read every credential", session: "a", configuration: aiConfig, key: "never-in-messages", modules: [aiModule], context: "test", knowledge: nil) { _, _ in await sequence.read() }
    #expect(result == "Unavailable")
    #expect(await sequence.reads == 0)
    let requests = await sequence.requests
    #expect(requests.last?.last?.content?.contains("rejected") == true)
    #expect(!(String(decoding: try JSONEncoder().encode(requests), as: UTF8.self)).contains("never-in-messages"))
}

@Test func aiOperationsAreSessionBoundSingleUseProposals() async throws {
    let sequence = AISequence([try call("request_operation", arguments: "{\"module\":\"demo/worker\",\"operation\":\"stop\"}"), AIMessage(role: "assistant", content: "Proposed")])
    let ai = KilnAssistant { _, _, messages, _ in await sequence.next(messages) }
    let result = try await ai.ask("Stop demo/worker", session: "a", configuration: aiConfig, key: "test", modules: [aiModule], context: "test", knowledge: nil) { _, _ in await sequence.read() }
    let id = String(try #require(result.components(separatedBy: "Outside chat: ai approve ").last))
    do { _ = try await ai.takeApproval(id, session: "b"); Issue.record("Cross-session approval allowed") } catch {}
    let action = try await ai.takeApproval(id, session: "a")
    #expect(action.operation == "stop" && action.module == "demo/worker")
    #expect(action.fingerprint == aiModule.generationFingerprint)
    #expect(await sequence.reads == 0)
    do { _ = try await ai.takeApproval(id, session: "a"); Issue.record("Approval replayed") } catch {}
}

@Test func aiReadToolsAndKnowledgeArePassedWithoutBroadeningPermissions() async throws {
    let sequence = AISequence([try call("list_modules", arguments: "{}"), AIMessage(role: "assistant", content: "One worker")])
    let ai = KilnAssistant { _, _, messages, _ in await sequence.next(messages) }
    let pack = try JSONDecoder().decode(AIKnowledgePack.self, from: Data("{\"version\":\"26.10.07.3\",\"notes\":\"Inventory module handles widgets.\"}".utf8))
    _ = try await ai.ask("Report", session: "a", configuration: aiConfig, key: "test", modules: [aiModule], context: "test", knowledge: pack) { _, _ in await sequence.read() }
    #expect(await sequence.reads == 1)
    #expect(await sequence.requests.first?.first?.content?.contains("Inventory module handles widgets.") == true)
}

@Test func nativeAIChatQuotesPromptsAndKeepsExplicitApprovalLocal() {
    var ui = KilnTerminal()
    _ = ui.handle(.text("`")); _ = ui.handle(.text("ai")); #expect(ui.handle(.enter).isEmpty)
    #expect(ui.render().contains("KILN AI CHAT"))
    _ = ui.handle(.text("what's running?"))
    #expect(ui.handle(.enter) == [.command("ai ask \"what's running?\"")])
    ui.finish(text: "Ready", status: 0)
    _ = ui.handle(.text("/approve test-id"))
    #expect(ui.handle(.enter) == [.command("ai approve test-id")])
}

@Test func staleAIProposalCannotStopChangedModule() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-ai-generation-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try KilnRuntime(stateDirectory: root)
    let manifest = ApplicationManifest(application: "demo", name: "worker", version: "1", executable: "/bin/sleep", arguments: ["60"])
    let path = root.appendingPathComponent("manifest.json")
    try JSONEncoder().encode(manifest).write(to: path)
    _ = try await runtime.install(path: path.path)
    let original = try #require(await runtime.snapshot().first).generationFingerprint
    _ = try await runtime.start("demo/worker")
    do {
        _ = try await runtime.performApprovedOperation("stop", name: "demo/worker", fingerprint: original)
        Issue.record("Stale proposal accepted")
    } catch {}
    #expect(await runtime.snapshot().first?.state == "running")
    await runtime.shutdown()
}

@Test func approvedOperationsPersistOutcomesAndRejectUnrecordedExecution() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try KilnRuntime(stateDirectory: root)
    let manifest = ApplicationManifest(name: "worker", version: "1", executable: "/bin/sleep", arguments: ["60"])
    let path = root.appendingPathComponent("manifest.json")
    try JSONEncoder().encode(manifest).write(to: path)
    _ = try await runtime.install(path: path.path)
    let fingerprint = try #require(await runtime.snapshot().first?.generationFingerprint)
    // The audit path is deliberately unavailable: no side effect may take place.
    let operations = root.appendingPathComponent("operations")
    try Data().write(to: operations)
    do {
        _ = try await runtime.performApprovedOperation("start", name: "default/worker", fingerprint: fingerprint)
        Issue.record("Started without an operation receipt")
    } catch {}
    #expect(await runtime.snapshot().first?.state == "stopped")
    try FileManager.default.removeItem(at: operations)
    _ = try await runtime.performApprovedOperation("start", name: "default/worker", fingerprint: fingerprint)
    #expect(try await runtime.operationHistory().contains("succeeded"))
    await runtime.shutdown()
    let restored = try KilnRuntime(stateDirectory: root)
    #expect(try await restored.operationHistory().contains("default/worker"))
}

@Test func aiChatIsVisibleAndOpensFromNavigation() {
    var ui = KilnTerminal()
    ui.resize(width: 120, height: 30)
    #expect(ui.render().contains("7 AI Chat"))
    _ = ui.handle(.text("7"))
    #expect(ui.render().contains("KILN AI CHAT"))
    _ = ui.handle(.text("report status"))
    #expect(ui.handle(.enter) == [.command("ai ask \"report status\"")])
    var mouse = KilnTerminal()
    mouse.resize(width: 120, height: 30)
    _ = mouse.handle(.mouse(button: 0, column: 77, row: 4, released: false))
    #expect(mouse.render().contains("KILN AI CHAT"))
    var compact = KilnTerminal()
    compact.resize(width: 50, height: 20)
    #expect(compact.render().contains("7 AI"))
}
