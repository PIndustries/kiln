import Foundation
import Testing
import KilnAI
import KilnKit
import KilnRuntime
@testable import KilnCommands

private let recoveryOwner = AIRecoveryTasks.Owner(name: "admin", publicKey: "test-public-key")
private actor RecoveryFixture {
    var executions = 0
    var generation = "original"
    var health: RecoveryEvidence.Health = .unhealthy
    var outcome: RecoveryReceipt?
    var failAfterEffect = false
    func inspect(_ module: String) -> RecoveryEvidence {
        .init(module: module, generation: generation, processState: "running", health: health)
    }
    func execute(_ id: String, _ module: String, _ expected: String) throws {
        #expect(expected == generation)
        executions += 1; generation = "replacement"; health = .healthy
        if failAfterEffect { outcome = .init(state: "started", generation: nil); throw AIError.message("simulated interruption after effect") }
        outcome = .init(state: "succeeded", generation: generation)
    }
    func configureFailure() { failAfterEffect = true }
    func receipt() -> RecoveryReceipt? { outcome }
    var controller: AIRecoveryTasks.Controller {
        .init(authorize: { _ in }, inspect: { await self.inspect($0) },
              execute: { try await self.execute($0, $1, $2) }, receipt: { _ in await self.receipt() })
    }
}
private func recoveryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
private func waitFor(_ tasks: AIRecoveryTasks, id: String, states: Set<AIRecoveryTasks.State>, owner: AIRecoveryTasks.Owner = recoveryOwner) async throws -> AIRecoveryTasks.Record {
    for _ in 0..<200 {
        let r = try await tasks.record(id, owner: owner)
        if states.contains(r.state) { return r }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw AIError.message("Recovery did not reach expected state")
}
private func submitRecovery(_ tasks: AIRecoveryTasks, controller: AIRecoveryTasks.Controller) async throws -> String {
    _ = try await tasks.submit(module: "demo/api", owner: recoveryOwner, controller: controller)
    return try #require(try await tasks.inventory(owner: recoveryOwner).first?.id)
}

@Test func recoverySurvivesReconnectAndConsumesApprovalOnce() async throws {
    let directory = try recoveryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = RecoveryFixture(), first = AIRecoveryTasks(directory: directory)
    let controller = await fixture.controller
    let id = try await submitRecovery(first, controller: controller)
    _ = try await waitFor(first, id: id, states: [.awaitingApproval])
    #expect(await fixture.executions == 0)
    // New controller instance models runtime restore, not just a terminal refresh.
    let restored = AIRecoveryTasks(directory: directory)
    #expect(try await restored.record(id, owner: recoveryOwner).before?.generation == "original")
    await #expect(throws: (any Error).self) {
        _ = try await restored.approve(id, owner: .init(name: "admin", publicKey: "different-key"), controller: controller)
    }
    async let firstApproval = restored.approve(id, owner: recoveryOwner, controller: controller)
    async let secondApproval = restored.approve(id, owner: recoveryOwner, controller: controller)
    _ = try await (firstApproval, secondApproval)
    let done = try await waitFor(restored, id: id, states: [.recovered])
    #expect(done.after?.health == .healthy)
    #expect(await fixture.executions == 1)
    let again = AIRecoveryTasks(directory: directory)
    _ = try await again.approve(id, owner: recoveryOwner, controller: controller)
    #expect(await fixture.executions == 1)
    #expect(try await again.record(id, owner: recoveryOwner).state == .recovered)
}

@Test func recoveryDoesNotReplayUncertainOperationEvenWhenHealthIsGood() async throws {
    let directory = try recoveryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tasks = AIRecoveryTasks(directory: directory), fixture = RecoveryFixture()
    await fixture.configureFailure()
    let controller = await fixture.controller
    let id = try await submitRecovery(tasks, controller: controller)
    _ = try await waitFor(tasks, id: id, states: [.awaitingApproval])
    _ = try await tasks.approve(id, owner: recoveryOwner, controller: controller)
    _ = try await waitFor(tasks, id: id, states: [.needsReview])
    let restarted = AIRecoveryTasks(directory: directory)
    _ = try await restarted.reconcile(id, owner: recoveryOwner, controller: controller)
    let result = try await waitFor(restarted, id: id, states: [.needsReview])
    #expect(result.after?.health == .healthy)
    #expect(result.state != .recovered)
    _ = try await restarted.approve(id, owner: recoveryOwner, controller: controller)
    #expect(await fixture.executions == 1)
}

@Test func recoveryDeniesExpiredApprovalsAndRechecksAuthority() async throws {
    let directory = try recoveryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tasks = AIRecoveryTasks(directory: directory), fixture = RecoveryFixture()
    let controller = await fixture.controller
    let id = try await submitRecovery(tasks, controller: controller)
    let pending = try await waitFor(tasks, id: id, states: [.awaitingApproval])
    let revoked = AIRecoveryTasks.Controller(authorize: { _ in throw AIError.message("revoked") }, inspect: controller.inspect, execute: controller.execute, receipt: controller.receipt)
    await #expect(throws: (any Error).self) { _ = try await tasks.approve(id, owner: recoveryOwner, controller: revoked) }
    #expect(await fixture.executions == 0)
    await #expect(throws: (any Error).self) { _ = try await tasks.approve(id, owner: recoveryOwner, controller: controller, now: pending.expires!) }
    _ = try await tasks.reconcile(id, owner: recoveryOwner, controller: controller)
    #expect(try await tasks.record(id, owner: recoveryOwner).state == .expired)
    #expect(await fixture.executions == 0)
}

@Test func recoveryCannotExecuteWhenJournalCommitFails() async throws {
    let directory = try recoveryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tasks = AIRecoveryTasks(directory: directory), fixture = RecoveryFixture()
    let controller = await fixture.controller
    let id = try await submitRecovery(tasks, controller: controller)
    _ = try await waitFor(tasks, id: id, states: [.awaitingApproval])
    let file = directory.appendingPathComponent("ai-recovery.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    await #expect(throws: (any Error).self) { _ = try await tasks.approve(id, owner: recoveryOwner, controller: controller) }
    #expect(await fixture.executions == 0)
}

@Test func recoveryRejectsCorruptJournalWithoutOverwritingIt() async throws {
    let directory = try recoveryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("ai-recovery.json"), bytes = Data("broken journal".utf8)
    try bytes.write(to: file)
    let tasks = AIRecoveryTasks(directory: directory), fixture = RecoveryFixture()
    await #expect(throws: (any Error).self) { _ = try await submitRecovery(tasks, controller: fixture.controller) }
    #expect(try Data(contentsOf: file) == bytes)
    #expect(await fixture.executions == 0)
}

@Test func runtimeOperationIDPreventsDuplicateRestartAndRejectsArgumentChanges() async throws {
    let directory = try recoveryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try KilnRuntime(stateDirectory: directory)
    let manifest = ApplicationManifest(application: "demo", name: "worker", version: "1", executable: "/bin/sleep", arguments: ["60"])
    let path = directory.appendingPathComponent("manifest.json")
    try JSONEncoder().encode(manifest).write(to: path)
    _ = try await runtime.install(path: path.path)
    _ = try await runtime.start("demo/worker")
    let original = try #require(await runtime.snapshot().first)
    let id = UUID().uuidString.lowercased()
    _ = try await runtime.performApprovedOperation("restart", name: original.id, fingerprint: original.generationFingerprint, requestID: id)
    let replacement = try #require(await runtime.snapshot().first)
    #expect(replacement.pid != original.pid)
    _ = try await runtime.performApprovedOperation("restart", name: original.id, fingerprint: original.generationFingerprint, requestID: id)
    #expect(await runtime.snapshot().first?.pid == replacement.pid)
    #expect(try await runtime.recoveryReceipt(id)?.generation == replacement.generationFingerprint)
    await #expect(throws: (any Error).self) {
        _ = try await runtime.performApprovedOperation("stop", name: original.id, fingerprint: original.generationFingerprint, requestID: id)
    }
    let evidence = try await runtime.recoveryEvidence(original.id)
    #expect(evidence.health == .unconfigured) // A process alone is not health proof.
    await runtime.shutdown()
}

@Test func coldRestoreCannotApproveAnOldStoppedGeneration() async throws {
    let directory = try recoveryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try KilnRuntime(stateDirectory: directory)
    let path = directory.appendingPathComponent("manifest.json")
    try JSONEncoder().encode(ApplicationManifest(name: "worker", version: "1", executable: "/bin/sleep", arguments: ["60"])).write(to: path)
    _ = try await runtime.install(path: path.path)
    let before = try #require(await runtime.snapshot().first)
    await runtime.shutdown()
    let restored = try KilnRuntime(stateDirectory: directory)
    try await restored.restore()
    let after = try #require(await restored.snapshot().first)
    #expect(before.pid == nil && after.pid == nil)
    #expect(before.generationFingerprint != after.generationFingerprint)
    await #expect(throws: (any Error).self) {
        _ = try await restored.performApprovedOperation("start", name: before.id, fingerprint: before.generationFingerprint)
    }
    #expect(await restored.snapshot().first?.state == "stopped")
    await restored.shutdown()
}

@Test func executingRecoveryJournalRestoresAsUnconfirmedWithoutExecution() async throws {
    let directory = try recoveryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tasks = AIRecoveryTasks(directory: directory), fixture = RecoveryFixture()
    let controller = await fixture.controller
    let id = try await submitRecovery(tasks, controller: controller)
    _ = try await waitFor(tasks, id: id, states: [.awaitingApproval])
    let path = directory.appendingPathComponent("ai-recovery.json")
    var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    var records = try #require(json["records"] as? [[String: Any]])
    records[0]["state"] = "executing"; json["records"] = records
    try JSONSerialization.data(withJSONObject: json).write(to: path)
    let restored = AIRecoveryTasks(directory: directory)
    #expect(try await restored.record(id, owner: recoveryOwner).state == .needsReview)
    _ = try await restored.approve(id, owner: recoveryOwner, controller: controller)
    #expect(await fixture.executions == 0)
}

@Test func recoveryToolCreatesDurableSidebarApprovalAndCannotApproveItself() async throws {
    let directory = try recoveryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try KilnRuntime(stateDirectory: directory)
    let assistant = KilnAssistant { _, _, _, tools in
        #expect(!tools.contains { $0.function.name == "approve" })
        let bytes = Data(#"{"id":"recover","type":"function","function":{"name":"create_recovery_task","arguments":"{\"module\":\"demo/api\"}"}}"#.utf8)
        return AIMessage(role: "assistant", content: nil, tool_calls: [try JSONDecoder().decode(AIToolCall.self, from: bytes)])
    }
    let commands = KilnCommands(runtime: runtime, assistant: assistant)
    let manifest = ApplicationManifest(application: "demo", name: "api", version: "1", executable: "/bin/sleep", arguments: ["60"], healthURL: "http://127.0.0.1:1/health")
    let path = directory.appendingPathComponent("manifest.json")
    try JSONEncoder().encode(manifest).write(to: path)
    _ = try await runtime.install(path: path.path)
    let config = AIConfiguration(baseURL: "http://127.0.0.1:11434", model: "fixture", secret: "", provider: .ollama, profile: "fixture")
    try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("ai.json"))
    let result = await commands.execute("ai ask investigate and recover demo/api", sessionID: "first-connection")
    #expect(result.status == 0 && result.text.contains("Recovery task created"))
    var workspace = await commands.aiWorkspace(sessionID: "new-connection")
    for _ in 0..<200 where workspace.proposals.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
        workspace = await commands.aiWorkspace(sessionID: "new-connection")
    }
    let proposal = try #require(workspace.proposals.first)
    #expect(proposal.id.hasPrefix("recovery:") && proposal.operation == "restart")
    #expect(workspace.tasks.contains { $0.id == proposal.id && $0.status == "awaitingApproval" })
    #expect(await runtime.snapshot().first?.state == "stopped")
    let denied = await commands.execute("ai deny " + proposal.id, sessionID: "new-connection")
    #expect(denied.status == 0)
    #expect(await commands.aiWorkspace(sessionID: "new-connection").proposals.isEmpty)
    await runtime.shutdown()
}
