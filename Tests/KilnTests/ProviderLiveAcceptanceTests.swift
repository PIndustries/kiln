import Foundation
import Testing
import Crypto
@testable import KilnAI
import KilnVault
import KilnKit

private final class AcceptanceFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var answers = 0
    private var bytes = 0
    private var cancellation: (@Sendable () -> Void)?
    func onFrame(_ event: AIProgress) {
        guard case .answer(let text) = event, !text.isEmpty else { return }
        lock.lock(); answers += 1; bytes += text.utf8.count; let cancel = cancellation; lock.unlock()
        cancel?()
    }
    func cancelOnAnswer(_ callback: @escaping @Sendable () -> Void) { lock.lock(); cancellation = callback; let seen = answers > 0; lock.unlock(); if seen { callback() } }
    var count: Int { lock.lock(); defer { lock.unlock() }; return answers }
}

/// Explicit opt-in only. Keys resolve inside this process from existing Vault grants.
/// Neither credential values nor model text appear in the emitted evidence record.
@Test func providerLiveAcceptance() async throws {
    let env = ProcessInfo.processInfo.environment
    guard env["KILN_PROVIDER_ACCEPTANCE"] == "1" else { return }
    guard let path = env["KILN_PROVIDER_STATE"] else { throw AIError.message("Acceptance state path required") }
    let directory = URL(fileURLWithPath: path)
    let profile = env["KILN_PROVIDER_PROFILE"] ?? "default"
    guard !profile.isEmpty, profile.count <= 32, profile.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }) else {
        throw AIError.message("Invalid acceptance profile")
    }
    let file = profile == "default" ? directory.appendingPathComponent("ai.json") : directory.appendingPathComponent("ai-profiles").appendingPathComponent(profile + ".json")
    let configuration = try JSONDecoder().decode(AIConfiguration.self, from: Data(contentsOf: file))
    try configuration.validate()
    let key: String
    if configuration.provider == .chatgpt {
        guard env["KILN_CHATGPT_LOCAL_CONSOLE"] == "1" else { throw AIError.message("Explicit local-console account acceptance required") }
        let owner = "local-console:" + SHA256.hash(data: Data("local-console".utf8)).map { String(format: "%02x", $0) }.joined()
        let service = try ChatGPTSignIn(directory: directory.appendingPathComponent("chatgpt-accounts"), vault: KilnVault(directory: directory))
        key = try await service.accessToken(account: configuration.secret, owner: owner, forceRefresh: env["KILN_CHATGPT_REFRESH"] == "1")
    }
    else if configuration.provider == .ollama { key = "" }
    else {
        guard let value = try KilnVault(directory: directory).environment(for: configuration.credentialScope, bindings: ["KEY": configuration.secret])["KEY"] else {
            throw AIError.message("Acceptance credential unavailable")
        }
        key = value
    }
    let metrics = AIProviderMetrics()
    let client = AIProviderClient(metrics: metrics)
    let frames = AcceptanceFrames()
    let tool = AITool("fixture_status", "Read the status of a disposable acceptance fixture. No arguments or side effects.")
    var history = [AIMessage(role: "system", content: "This is a bounded transport acceptance check. Call fixture_status exactly once, then report its status in one short sentence. Do not invent results."), AIMessage(role: "user", content: "Call fixture_status now.")]
    var stage = "tool-selection"
    do {
        let call: AIMessage
        if configuration.provider == .chatgpt {
            // A transport test requires the synthetic tool; model choice with
            // tool_choice=auto is not a deterministic interoperability assertion.
            var request = try OpenAIResponsesClient.makeRequest(configuration: configuration, key: key, messages: history, tools: [tool])
            var body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            body["tool_choice"] = "required"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let prepared = request
            call = try await metrics.measure {
                try await OpenAIResponsesClient().streamAttempt(request: prepared, allowMissingContentType: true, reconstructCompletedOutput: true) { frames.onFrame($0) }
            }
            await metrics.recordUsage(provider: configuration.provider, usage: call.usage)
        } else {
            call = try await client.stream(configuration: configuration, key: key, messages: history, tools: [tool]) { frames.onFrame($0) }
        }
        let nameKind = call.tool_calls?.first?.function.name == "fixture_status" ? "plain" : call.tool_calls?.first?.function.name == "kiln.fixture_status" ? "qualified" : "other"
        stage = "tool-selection-count-\(call.tool_calls?.count ?? 0)-name-\(nameKind)"
        guard let calls = call.tool_calls, calls.count == 1, calls[0].function.name == "fixture_status",
              let arguments = try? JSONSerialization.jsonObject(with: Data(calls[0].function.arguments.utf8)) as? [String: Any], arguments.isEmpty else {
            throw AIError.message("Acceptance tool selection failed")
        }
        history.append(call)
        history.append(AIMessage(role: "tool", content: "{\"status\":\"healthy\",\"fixture\":true}", tool_call_id: calls[0].id))
        stage = "tool-result"
        let answer = try await client.stream(configuration: configuration, key: key, messages: history, tools: []) { frames.onFrame($0) }
        guard answer.tool_calls?.isEmpty != false, answer.content?.lowercased().contains("healthy") == true, frames.count > 0 else {
            throw AIError.message("Acceptance final answer failed")
        }
        let cancellationFrames = AcceptanceFrames()
        stage = "cancellation"
        let task = Task {
            try await client.stream(configuration: configuration, key: key,
                messages: [AIMessage(role: "user", content: "Write the integers from 1 through 200, one per line, with no introduction.")], tools: []) { cancellationFrames.onFrame($0) }
        }
        cancellationFrames.cancelOnAnswer { task.cancel() }
        var cancelled = false
        do { _ = try await task.value } catch is CancellationError { cancelled = true }
        guard cancelled, cancellationFrames.count > 0 else { throw AIError.message("Acceptance cancellation after streamed content failed") }
        print("KILN_PROVIDER_ACCEPTANCE provider=\(configuration.provider.rawValue) tool_round=pass answer_frames=\(frames.count) cancellation=pass")
    } catch {
        // Do not print provider bodies, prompts, endpoint/account identifiers or secrets.
        let counters = await metrics.snapshot()
        let categories = counters.outcomes.filter { $0.value > 0 }.keys.sorted().joined(separator: ",")
        print("KILN_PROVIDER_ACCEPTANCE provider=\(configuration.provider.rawValue) result=failed stage=\(stage) outcomes=\(categories)")
        throw AIError.message("Live provider acceptance failed; inspect redacted provider counters and account configuration")
    }
}
