import Foundation
import Testing
import KilnAI
import KilnKit
import KilnRuntime
@testable import KilnCommands

private actor VaultContextProbe {
    private var expectedKey: String
    private var acceptedKeys: [Bool] = []
    private var messages: [[AIMessage]] = []
    init(expectedKey: String) { self.expectedKey = expectedKey }
    func expectKey(_ value: String) { expectedKey = value }
    func complete(key: String, context: [AIMessage]) throws -> AIMessage {
        acceptedKeys.append(key == expectedKey)
        messages.append(context)
        if context.contains(where: { $0.role == "tool" }) {
            return AIMessage(role: "assistant", content: "Inspected permitted system metadata.")
        }
        let specifications: [(String, [String: String])] = [
            ("system_status", [:]), ("list_modules", [:]), ("host_metrics", [:]),
            ("module_resources", ["module": "sample/worker"]),
            ("release_info", ["module": "sample/worker"]),
            ("vault_read", ["name": "module-credential"])
        ]
        let calls = try specifications.enumerated().map { index, item in
            let arguments = String(decoding: try JSONEncoder().encode(item.1), as: UTF8.self)
            let bytes = try JSONSerialization.data(withJSONObject: ["id": "fixture-\(index)", "type": "function", "function": ["name": item.0, "arguments": arguments]])
            return try JSONDecoder().decode(AIToolCall.self, from: bytes)
        }
        return AIMessage(role: "assistant", content: nil, tool_calls: calls)
    }
    func snapshot() throws -> (Bool, Int, String) {
        (acceptedKeys.allSatisfy { $0 }, acceptedKeys.count, String(decoding: try JSONEncoder().encode(messages), as: UTF8.self))
    }
}

@Test func vaultCanariesStayOutOfAuditsTelemetryAndAIContext() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("kiln-vault-exposure-" + UUID().uuidString)
    try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? files.removeItem(at: root) }
    let runtime = try KilnRuntime(stateDirectory: root.appendingPathComponent("state"))
    _ = try runtime.vault.initialize(keyFile: root.appendingPathComponent("master.key"))
    let first = "disposable-ai-" + UUID().uuidString
    let replacement = "disposable-ai-" + UUID().uuidString
    let moduleValue = "disposable-module-" + UUID().uuidString
    let probe = VaultContextProbe(expectedKey: first)
    let assistant = KilnAssistant { _, key, messages, _ in try await probe.complete(key: key, context: messages) }
    let commands = KilnCommands(runtime: runtime, assistant: assistant)
    var output = [String]()
    for (name, value) in [("provider-credential", first), ("module-credential", moduleValue)] {
        let result = commands.putSecret(name: name, value: value)
        #expect(result.status == 0)
        output.append(result.text)
    }
    let manifest = ApplicationManifest(application: "sample", name: "worker", version: "1", executable: "/bin/sleep", arguments: ["60"], secrets: ["TOKEN": "module-credential"])
    let path = root.appendingPathComponent("module.json")
    try JSONEncoder().encode(manifest).write(to: path)
    _ = try await runtime.install(path: path.path)
    for line in ["ai configure https://fixture.invalid/v1 fixture provider-credential", "vault grant kiln/ai provider-credential", "metrics", "vault list"] {
        let result = await commands.execute(line)
        #expect(result.status == 0)
        output.append(result.text)
    }
    let denied = await commands.execute("app start sample/worker")
    #expect(denied.status != 0)
    output.append(denied.text)
    for (session, value) in [("before", first), ("after", replacement)] {
        if session == "after" {
            let changed = commands.putSecret(name: "provider-credential", value: value)
            #expect(changed.status == 0)
            output.append(changed.text)
            await probe.expectKey(replacement)
        }
        let result = await commands.execute("ai ask Inspect system metadata", sessionID: session)
        #expect(result.status == 0)
        output.append(result.text)
    }
    let beforeDenial = try await probe.snapshot()
    let correctProviderKeys = beforeDenial.0
    let callCount = beforeDenial.1
    let containsMetrics = beforeDenial.2.contains("host_metrics")
    let deniedVaultTool = beforeDenial.2.contains("rejected")
    #expect(correctProviderKeys)
    #expect(callCount == 6) // Tool request, draft and presentation for each turn.
    #expect(containsMetrics)
    #expect(deniedVaultTool)
    _ = try runtime.vault.revoke("provider-credential", from: "kiln/ai")
    let blocked = await commands.execute("ai ask Inspect again", sessionID: "revoked")
    #expect(blocked.status != 0)
    output.append(blocked.text)
    let afterDenial = try await probe.snapshot()
    let noNewProviderCall = afterDenial.1 == callCount
    #expect(noNewProviderCall)
    output.append(afterDenial.2)
    let audit = runtime.stateDirectory.appendingPathComponent("audit")
    let auditFiles = try files.contentsOfDirectory(at: audit, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
    #expect(!auditFiles.isEmpty)
    for file in auditFiles { output.append(try String(contentsOf: file, encoding: .utf8)) }
    let combined = output.joined(separator: "\n")
    let leaked = [first, replacement, moduleValue].contains { combined.contains($0) }
    #expect(!leaked) // Boolean-only diagnostics cannot print any canary.
    await runtime.shutdown()
}
