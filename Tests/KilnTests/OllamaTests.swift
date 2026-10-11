import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KilnAI
import KilnKit
import KilnRuntime
@testable import KilnCommands

private func localConfiguration(_ model: String = "fixture") -> AIConfiguration {
    AIConfiguration(baseURL: model == "waiting" ? "http://127.0.0.1:11435" : "http://127.0.0.1:11434", model: model, secret: "", provider: .ollama, profile: "local")
}
@Test func aiLegacyConfigurationAndLocalProviderBoundary() throws {
    let legacy = try JSONDecoder().decode(AIConfiguration.self, from: Data(#"{"baseURL":"https://example.invalid/v1","model":"fixture","secret":"api"}"#.utf8))
    #expect(legacy.provider == .erebine && legacy.credentialScope == "kiln/ai")
    try legacy.validate(); try localConfiguration().validate()
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
    #expect(encoded?["schemaVersion"] as? Int == 1)
    #expect(throws: AIError.self) {
        _ = try JSONDecoder().decode(AIConfiguration.self, from: Data(#"{"schemaVersion":99,"baseURL":"https://example.invalid","model":"fixture","secret":"api"}"#.utf8))
    }
    for url in ["http://localhost:11434", "http://192.168.1.1:11434", "https://ollama.com", "http://127.0.0.1@remote.invalid", "http://127.0.0.1/api", "http://127.0.0.1?token=x"] {
        #expect(throws: AIError.self) { try AIConfiguration(baseURL: url, model: "fixture", secret: "", provider: .ollama).validate() }
    }
    #expect(throws: AIError.self) { try AIConfiguration(baseURL: "http://127.0.0.1", model: "fixture", secret: "unwanted", provider: .ollama).validate() }
}
@Test func ollamaNDJSONNormalizesStreamingAndTools() throws {
    var decoder = OllamaStreamDecoder()
    let first = #"{"message":{"role":"assistant","content":"Hi ☀","thinking":"checking"},"done":false}"# + "\n"
    for byte in first.utf8 { try decoder.feed(Data([byte]), emit: { _ in }) }
    #expect(!decoder.done)
    #expect(throws: AIError.self) { var incomplete = decoder; _ = try incomplete.finish(emit: { _ in }) }
    try decoder.feed(Data((#"{"message":{"role":"assistant","tool_calls":[{"function":{"name":"system_status","arguments":{}}}]},"done":false}"# + "\n" + #"{"message":{"role":"assistant","content":"!"},"done":true,"done_reason":"stop"}"# + "\n").utf8), emit: { _ in })
    let message = try decoder.finish(emit: { _ in })
    #expect(message.content == "Hi ☀!" && message.reasoning_content == "checking")
    let call = try #require(message.tool_calls?.first)
    #expect(call.function.name == "system_status" && call.function.arguments == "{}")
    let request = try OllamaClient().request(configuration: localConfiguration(), messages: [message, AIMessage(role: "tool", content: "verified", tool_call_id: call.id)], tools: [])
    #expect(request.url?.path == "/api/chat" && request.value(forHTTPHeaderField: "Authorization") == nil)
    let json = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
    #expect(json["keep_alive"] as? String == "1m")
    #expect((json["options"] as? [String: Int])?["num_ctx"] == 8192)
    let messages = try #require(json["messages"] as? [[String: Any]])
    #expect(messages[1]["tool_name"] as? String == "system_status")
    #expect(messages[0]["thinking"] as? String == "checking")
}
@Test func ollamaRejectsTruncatedOversizedAndMalformedCalls() throws {
    for line in [#"{"done":true,"done_reason":"length"}"#, #"{"error":"private provider detail","done":true}"#, #"{"message":{"role":"assistant","tool_calls":[{"function":{"name":"system_status","arguments":"{}"}}]},"done":false}"#] {
        var decoder = OllamaStreamDecoder()
        #expect(throws: (any Error).self) { try decoder.feed(Data((line + "\n").utf8), emit: { _ in }) }
    }
    var decoder = OllamaStreamDecoder()
    #expect(throws: AIError.self) { try decoder.feed(Data(repeating: 65, count: 262145), emit: { _ in }) }
}
private final class OllamaProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = request.httpBody ?? Data()
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let model = request.url?.port == 11435 ? "waiting" : object?["model"] as? String ?? "fixture"
        let response = HTTPURLResponse(url: request.url!, statusCode: model == "unauthorized" ? 401 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/x-ndjson"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if model == "waiting" { return }
        if model == "unauthorized" { client?.urlProtocolDidFinishLoading(self); return }
        for text in [#"{"message":{"role":"assistant","content":"hello"},"done":false}"#, #"{"message":{"role":"assistant","content":" world"},"done":true,"done_reason":"stop"}"#] {
            client?.urlProtocol(self, didLoad: Data((text + "\n").utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private func ollamaSession() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OllamaProtocol.self]; return config
}
@Test func ollamaNativeTransportAndCancellation() async throws {
    let result = try await OllamaClient().stream(configuration: localConfiguration(), messages: [], tools: [], sessionConfiguration: ollamaSession(), emit: { _ in })
    #expect(result.content == "hello world")
    let task = Task { try await OllamaClient().stream(configuration: localConfiguration("waiting"), messages: [], tools: [], sessionConfiguration: ollamaSession(), emit: { _ in }) }
    try await Task.sleep(for: .milliseconds(50)); task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled Ollama transport returned success") }
    catch { #expect(error is CancellationError) }
}
private actor ProfileCapture {
    var leaked = false
    func completion(_ configuration: AIConfiguration, _ messages: [AIMessage]) -> AIMessage {
        if configuration.profile == "second" { leaked = leaked || messages.contains { $0.content?.contains("private-first-context") == true } }
        return AIMessage(role: "assistant", content: "done")
    }
}
@Test func providerChangesNeverForwardPriorConversation() async throws {
    let capture = ProfileCapture()
    let assistant = KilnAssistant { configuration, _, messages, _ in await capture.completion(configuration, messages) }
    let first = localConfiguration()
    let second = AIConfiguration(baseURL: "https://example.invalid/v1", model: "fixture", secret: "second-key", profile: "second")
    for session in ["one", "two"] {
        _ = try await assistant.ask("private-first-context", session: session, configuration: first, key: "", modules: [], context: "", knowledge: nil) { _, _ in "" }
        _ = try await assistant.ask("new turn", session: session, configuration: second, key: "fixture", modules: [], context: "", knowledge: nil) { _, _ in "" }
    }
    #expect(await !capture.leaked)
}
@Test func namedProviderProfilesRequireExplicitSelectionAndScope() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try KilnRuntime(stateDirectory: directory)
    let commands = KilnCommands(runtime: runtime)
    let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    try commands.bootstrapIdentity(username: "admin", keys: [key])
    #expect(await commands.execute("ai profile add local ollama http://127.0.0.1:11434 fixture").status == 0)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("ai.json").path))
    #expect(await commands.execute("ai profile use local").status != 0)
    #expect(await commands.execute("ai profile use local --new-context").status == 0)
    let active = try JSONDecoder().decode(AIConfiguration.self, from: Data(contentsOf: directory.appendingPathComponent("ai.json")))
    #expect(active.provider == .ollama && active.secret.isEmpty)
    #expect(await commands.aiWorkspace().provider?.label == "ollama / local")
    #expect(await commands.execute("ai profile add hosted erebine https://example.invalid/v1 fixture scoped-key").status == 0)
    let hosted = try JSONDecoder().decode(AIConfiguration.self, from: Data(contentsOf: directory.appendingPathComponent("ai-profiles/hosted.json")))
    #expect(hosted.credentialScope == "kiln/ai-hosted")
    #expect(await commands.execute("ai profile use hosted --new-context").status == 0)
    #expect(await commands.aiWorkspace().provider?.label == "erebine / hosted")
    let auditURL = directory.appendingPathComponent("audit")
    let records = try FileManager.default.contentsOfDirectory(at: auditURL, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
    let audit = try records.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
    #expect(audit.contains("ai profile") && !audit.contains("ai unknown"))
    #expect(await commands.execute("ai profile list").status == 0)
    let afterList = try FileManager.default.contentsOfDirectory(at: auditURL, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
    #expect(afterList.count == records.count)
    _ = try commands.identities.set(name: "viewer", role: "viewer", key: key, modules: [])
    #expect(await commands.forIdentity(name: "viewer", publicKey: key).execute("ai profile use local --new-context").status != 0)
    await runtime.shutdown()
}

private actor TaskProfileCapture {
    var models: [String] = []
    var released = false
    var gate: CheckedContinuation<Void, Never>?
    func complete(_ configuration: AIConfiguration) async -> AIMessage {
        models.append(configuration.model)
        if !released { await withCheckedContinuation { gate = $0 } }
        return AIMessage(role: "assistant", content: "checked")
    }
    func release() { released = true; gate?.resume(); gate = nil }
}
@Test func queuedTasksKeepOriginalProviderProfileAfterSelection() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try KilnRuntime(stateDirectory: directory)
    let capture = TaskProfileCapture()
    let assistant = KilnAssistant { configuration, _, _, _ in await capture.complete(configuration) }
    let commands = KilnCommands(runtime: runtime, assistant: assistant)
    let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    try commands.bootstrapIdentity(username: "admin", keys: [key])
    #expect(await commands.execute("ai profile add local ollama http://127.0.0.1:11434 first").status == 0)
    #expect(await commands.execute("ai profile add other ollama http://127.0.0.1:11434 second").status == 0)
    #expect(await commands.execute("ai profile use local --new-context").status == 0)
    #expect(await commands.execute("ai concurrency 1").status == 0)
    #expect(await commands.execute("ai task new first investigation").status == 0)
    for _ in 0..<500 {
        if await !capture.models.isEmpty { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await capture.models == ["first"])
    #expect(await commands.execute("ai task new queued investigation").status == 0)
    #expect(await commands.execute("ai profile use other --new-context").status == 0)
    await capture.release()
    var finished = false
    for _ in 0..<500 {
        let listing = await commands.execute("ai task list")
        if listing.text.components(separatedBy: "completed").count >= 3 { finished = true; break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(finished)
    #expect(await capture.models.count >= 2)
    #expect(await capture.models.allSatisfy { $0 == "first" })
    await runtime.shutdown()
}

private final class LiveProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func receive(_ event: AIProgress) {
        if case .answer(let text) = event, !text.isEmpty { lock.lock(); count += 1; lock.unlock() }
    }
    var chunks: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Opt-in local-only smoke test. Never downloads a model or contacts paid APIs.
@Test(.enabled(if: ProcessInfo.processInfo.environment["KILN_TEST_OLLAMA_MODEL"] != nil))
func ollamaLiveLocalStreamingAndToolRound() async throws {
    let model = try #require(ProcessInfo.processInfo.environment["KILN_TEST_OLLAMA_MODEL"])
    let config = localConfiguration(model)
    let metrics = AIProviderMetrics()
    let client = AIProviderClient(metrics: metrics)
    let messages = [AIMessage(role: "system", content: "You are a test assistant. Call system_status to inspect this disposable fixture before answering; after a tool result, report it briefly without another call. /no_think"),
                    AIMessage(role: "user", content: "Call system_status now. /no_think")]
    let first = try await client.stream(configuration: config, key: "", messages: messages, tools: [AITool("system_status", "Get the disposable fixture status")], emit: { _ in })
    let call = try #require(first.tool_calls?.first)
    #expect(call.function.name == "system_status")
    let progress = LiveProgressCounter()
    let final = try await client.stream(configuration: config, key: "", messages: messages + [first, AIMessage(role: "tool", content: "Disposable Kiln fixture: healthy. No real services or credentials.", tool_call_id: call.id), AIMessage(role: "user", content: "Report the fixture status from that result in one sentence. Do not call tools again. /no_think")], tools: [], emit: { progress.receive($0) })
    #expect(!(final.content ?? "").isEmpty)
    #expect(final.tool_calls == nil)
    #expect(progress.chunks > 1)
    let snapshot = await metrics.snapshot()
    #expect(snapshot.started == 2 && snapshot.outcomes["completed"] == 2 && snapshot.active == 0)
}

@Test func localOllamaRefusesProxyEnvironmentWithoutExposingValues() throws {
    try OllamaClient.validateProxyEnvironment([:])
    try OllamaClient.validateProxyEnvironment(["NO_PROXY": "127.0.0.1", "HTTP_PROXY": ""])
    let canary = "http://synthetic-private-proxy.invalid:8765"
    for key in ["http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"] {
        do {
            try OllamaClient.validateProxyEnvironment([key: canary, "NO_PROXY": "*"])
            Issue.record("Proxy-configured local transport was admitted")
        } catch {
            let withheld = !String(describing: error).contains(canary)
            #expect(withheld)
            #expect(String(describing: error).contains("Local Ollama is disabled"))
        }
    }
}
