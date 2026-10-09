import Foundation
import Testing
import KilnAI
import KilnKit
import KilnRuntime
@testable import KilnCommands

private let workspaceKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
private func workspaceAssistant() -> KilnAssistant {
    KilnAssistant { _, _, messages, _ in
        if messages.last?.role == "tool" { return AIMessage(role: "assistant", content: "Proposed") }
        let bytes = Data("{\"id\":\"proposal\",\"type\":\"function\",\"function\":{\"name\":\"request_operation\",\"arguments\":\"{\\\"module\\\":\\\"demo/worker\\\",\\\"operation\\\":\\\"stop\\\"}\"}}".utf8)
        return AIMessage(role: "assistant", content: nil, tool_calls: [try JSONDecoder().decode(AIToolCall.self, from: bytes)])
    }
}
private func propose(_ assistant: KilnAssistant, session: String) async throws {
    _ = try await assistant.ask("Stop worker", session: session,
        configuration: AIConfiguration(baseURL: "https://fixture.invalid/v1", model: "test", secret: "test"), key: "fixture",
        modules: [ModuleSnapshot(application: "demo", name: "worker", version: "1", state: "running", pid: 42)], context: "", knowledge: nil) { _, _ in "" }
}
@Test func workspaceProposalsAreTypedSessionBoundExpiringAndSingleUse() async throws {
    let assistant = workspaceAssistant()
    try await propose(assistant, session: "admin:first")
    let rows = await assistant.pendingProposals(session: "admin:first")
    let row = try #require(rows.first)
    #expect(rows.count == 1 && row.operation == "stop" && row.module == "demo/worker")
    #expect(await assistant.pendingProposals(session: "admin:other").isEmpty)
    #expect(await assistant.pendingProposals(session: "admin:first", now: row.expires).isEmpty)
    _ = try await assistant.takeApproval(row.id, session: "admin:first")
    #expect(await assistant.pendingProposals(session: "admin:first").isEmpty)
    try await propose(assistant, session: "admin:first")
    let denied = try #require(await assistant.pendingProposals(session: "admin:first").first)
    _ = try await assistant.deny(denied.id, session: "admin:first")
    #expect(await assistant.pendingProposals(session: "admin:first").isEmpty)
}
@Test func workspaceClearsPrivateInventoryOnScopeDemotionAndRevocation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try KilnRuntime(stateDirectory: directory)
    let taskID = UUID().uuidString.lowercased()
    let journal: [String: Any] = ["concurrency":4,"records":[["id":taskID,"prompt":"private task prompt","state":"completed","output":"private output","created":0]]]
    try KilnStateFile.write(JSONSerialization.data(withJSONObject: journal), to: directory.appendingPathComponent("ai-tasks.json"))
    let assistant = workspaceAssistant()
    let commands = KilnCommands(runtime: runtime, assistant: assistant)
    try commands.bootstrapIdentity(username: "admin", keys: [workspaceKey])
    _ = try commands.identities.set(name: "user", role: "admin", key: workspaceKey, modules: [])
    let user = commands.forIdentity(name: "user", publicKey: workspaceKey)
    try await propose(assistant, session: "user:current")
    let initial = await user.aiWorkspace(sessionID: "current")
    #expect(initial.proposals.count == 1)
    #expect(initial.tasks == [AITaskSnapshot(id: taskID, prompt: "private task prompt", status: "completed")])
    #expect(await user.aiWorkspace(sessionID: "other").proposals.isEmpty)
    _ = try commands.identities.set(name: "user", role: "operator", key: nil, modules: ["demo/worker"])
    let scoped = await user.aiWorkspace(sessionID: "current")
    #expect(scoped.proposals.count == 1 && scoped.tasks.isEmpty)
    _ = try commands.identities.set(name: "user", role: "operator", key: nil, modules: ["different/worker"])
    #expect(await user.aiWorkspace(sessionID: "current").proposals.isEmpty)
    _ = try commands.identities.set(name: "user", role: "viewer", key: nil, modules: [])
    let viewer = await user.aiWorkspace(sessionID: "current")
    #expect(viewer.tasks.isEmpty && viewer.proposals.isEmpty)
    _ = try commands.identities.set(name: "user", role: "viewer", key: nil, modules: [], revoke: true)
    let revoked = await user.aiWorkspace(sessionID: "current")
    #expect(revoked.tasks.isEmpty && revoked.proposals.isEmpty && revoked.error != nil)
    await runtime.shutdown()
}
