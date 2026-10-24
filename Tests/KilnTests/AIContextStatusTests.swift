import Foundation
import Testing
import KilnAI
import KilnKit
import KilnRuntime
import KilnTerminal
@testable import KilnCommands

private let statusConfig = AIConfiguration(baseURL: "http://127.0.0.1:11434", model: "fixture", secret: "", provider: .ollama)
private func statusAsk(_ assistant: KilnAssistant, _ prompt: String, session: String) async throws -> String {
    try await assistant.ask(prompt, session: session, configuration: statusConfig, key: "", modules: [], context: "fixture", knowledge: nil) { _, _ in "unused" }
}

@Test func contextStatusReportsOnlyMetadataForTheRequestedSession() async throws {
    let assistant = KilnAssistant { _, _, _, _ in AIMessage(role: "assistant", content: "private answer") }
    let empty = await assistant.contextStatus("chat")
    #expect(empty.contains("State: empty") && empty.contains("Completed turns: 0"))
    #expect(empty.contains("0 messages / 40 limit") && empty.contains("2 bytes / 65536 limit"))
    _ = try await statusAsk(assistant, "PRIVATE_PROMPT_NEVER_PRINT", session: "chat")
    await assistant.record("PRIVATE_OPERATION_RESULT", session: "chat")
    let status = await assistant.contextStatus("chat")
    #expect(status.contains("State: active") && status.contains("Completed turns: 1"))
    #expect(status.contains("Stored history: 3 messages"))
    #expect(!status.contains("PRIVATE_PROMPT") && !status.contains("PRIVATE_OPERATION") && !status.contains("private answer"))
    #expect(status.contains("not the model's token window"))
    #expect(await assistant.contextStatus("other").contains("Completed turns: 0"))
}

@Test func contextStatusForecastsTrimmingAndExpiryWithoutChangingHistory() async throws {
    let assistant = KilnAssistant { _, _, _, _ in AIMessage(role: "assistant", content: "answer") }
    for _ in 0..<21 { _ = try await statusAsk(assistant, "question", session: "chat") }
    let status = await assistant.contextStatus("chat")
    #expect(status.contains("Completed turns: 21") && status.contains("42 messages / 40 limit"))
    #expect(status.contains("Next request: oldest complete turns will be omitted"))
    let future = await assistant.contextStatus("chat", now: Date().addingTimeInterval(3601))
    #expect(future.contains("State: expired") && future.contains("fresh context after idle expiry"))
    #expect(future.contains("Idle expiry: 0 seconds remaining"))
    #expect(await assistant.contextStatus("chat").contains("Completed turns: 21"))
    let answer = try await statusAsk(assistant, "next", session: "chat")
    #expect(answer.contains("Context trimmed:"))
    _ = try await assistant.reset("chat")
    #expect(await assistant.contextStatus("chat").contains("State: empty"))
}

@Test func contextCommandIsConnectionScopedAndAvailableToViewersWithoutProviderConfiguration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let assistant = KilnAssistant { _, _, _, _ in AIMessage(role: "assistant", content: "answer") }
    _ = try await statusAsk(assistant, "PRIVATE_READER_PROMPT", session: "reader:shared")
    let runtime = try KilnRuntime(stateDirectory: directory)
    let local = KilnCommands(runtime: runtime, assistant: assistant)
    let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    try local.bootstrapIdentity(username: "admin", keys: [key])
    _ = try local.identities.set(name: "reader", role: "viewer", key: key, modules: [])
    _ = try local.identities.set(name: "other", role: "viewer", key: key, modules: [])
    let reader = local.forIdentity(name: "reader", publicKey: key)
    let result = await reader.execute("ai context", sessionID: "shared")
    #expect(result.status == 0 && result.text.contains("Completed turns: 1"))
    #expect(!result.text.contains("PRIVATE_READER_PROMPT"))
    #expect(await reader.execute("ai context", sessionID: "different").text.contains("Completed turns: 0"))
    #expect(await local.forIdentity(name: "other", publicKey: key).execute("ai context", sessionID: "shared").text.contains("Completed turns: 0"))
    _ = try local.identities.set(name: "reader", role: "viewer", key: nil, modules: [], revoke: true)
    #expect(await reader.execute("ai context", sessionID: "shared").status != 0)
    await runtime.shutdown()
}

@Test func chatContextShortcutUsesTheLocalCommandAndKeepsChatOpen() {
    var terminal = KilnTerminal()
    _ = terminal.handle(.text("`")); _ = terminal.handle(.text("ai")); _ = terminal.handle(.enter)
    _ = terminal.handle(.text("/context"))
    #expect(terminal.handle(.enter) == [.command("ai context")])
    terminal.finish(text: "AI context / current connection\nCompleted turns: 0", status: 0)
    #expect(terminal.chatVisible && !terminal.busy)
    #expect(terminal.render().contains("Completed turns: 0"))
}
