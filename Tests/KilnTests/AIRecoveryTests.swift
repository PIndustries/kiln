import Foundation
import Testing
import KilnAI
import KilnRuntime

private struct RecoveryTaskRecord: Codable {
    let id: String
    let prompt: String
    let state: String
    let output: String
    let created: Date
}
private struct RecoveryTaskIndex: Codable {
    let concurrency: Int
    let records: [RecoveryTaskRecord]
}

@Test func taskRecoveryInterruptsOnlyUnfinishedWorkAndPersistsTheDecision() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("ai-tasks.json")
    let states = ["queued", "running", "completed", "failed", "cancelled", "interrupted", "unconfirmed"]
    let original = RecoveryTaskIndex(concurrency: 3, records: states.map {
        RecoveryTaskRecord(id: $0, prompt: "Investigate \($0)", state: $0, output: "Recorded \($0)", created: Date())
    })
    try JSONEncoder().encode(original).write(to: file)
    let recovered = AITasks(directory: directory)
    for state in states {
        let record = try await recovered.show(state)
        if ["queued", "running"].contains(state) {
            #expect(record.contains("[interrupted]"))
            #expect(record.contains("not automatically replayed"))
        } else {
            #expect(record.contains("[\(state)]"))
            #expect(record.contains("Recorded \(state)"))
        }
    }
    #expect(try await recovered.limit().contains("3/48; active 0"))
    let saved = try JSONDecoder().decode(RecoveryTaskIndex.self, from: Data(contentsOf: file))
    #expect(saved.records.filter { $0.state == "interrupted" }.count == 3)
    #expect(!saved.records.contains { ["queued", "running"].contains($0.state) })
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    // A second startup observes the committed recovery decision, not runnable work.
    let restartedAgain = AITasks(directory: directory)
    #expect(try await restartedAgain.show("running").contains("[interrupted]"))
    let stream = try await restartedAgain.watch("running")
    var snapshots: [String] = []
    for await snapshot in stream { snapshots.append(snapshot) }
    #expect(snapshots.count == 1)
}

@Test func malformedTaskJournalIsNotReplacedWithAnEmptyHistory() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("ai-tasks.json")
    let original = Data("{\"concurrency\":4,\"records\":[".utf8)
    try original.write(to: file)
    let recovered = AITasks(directory: directory)
    await #expect(throws: (any Error).self) { _ = try await recovered.list() }
    await #expect(throws: (any Error).self) {
        _ = try await recovered.submit("must not run") { _, _, _ in
            Issue.record("Runner executed despite corrupt task journal")
            return "unexpected"
        }
    }
    #expect(try Data(contentsOf: file) == original)
}

@Test func incompleteOperationReceiptRemainsUnconfirmedAcrossRestore() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let operations = directory.appendingPathComponent("operations")
    try FileManager.default.createDirectory(at: operations, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = operations.appendingPathComponent("interrupted.json")
    let receipt = ["id": "interrupted", "state": "started", "operation": "restart", "module": "example/worker", "startedAt": "2026-10-08T00:00:00Z"]
    let bytes = try JSONEncoder().encode(receipt)
    try bytes.write(to: path)
    let runtime = try KilnRuntime(stateDirectory: directory)
    try await runtime.restore()
    #expect(await runtime.snapshot().isEmpty)
    #expect(try await runtime.operationHistory().contains("unconfirmed (inspect state; do not blindly retry)"))
    #expect(try Data(contentsOf: path) == bytes)
    await runtime.shutdown()
}
