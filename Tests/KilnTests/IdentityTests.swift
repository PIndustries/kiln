import Foundation
import Testing
import KilnKit
import KilnRuntime
import KilnCommands

private let identityKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

@Test func identityScopesRolesAndRevocationApplyToBoundCommands() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try KilnRuntime(stateDirectory: directory)
    let local = KilnCommands(runtime: runtime)
    try local.bootstrapIdentity(username: "admin", keys: [identityKey])
    _ = try local.identities.set(name: "reader", role: "viewer", key: identityKey, modules: ["sample/worker"])
    _ = try local.identities.set(name: "operator", role: "operator", key: identityKey, modules: ["sample/worker"])
    let reader = local.forIdentity(name: "reader", publicKey: identityKey)
    let operatorUser = local.forIdentity(name: "operator", publicKey: identityKey)
    #expect(reader.isAuthorized())
    #expect(await reader.execute("status").status == 0)
    for command in ["app start sample/worker", "app health other/worker", "vault list", "server list", "session list", "key list", "identity list", "ai task list", "ai configure https://example.com model secret", "node list"] {
        #expect(await reader.execute(command).status != 0)
    }
    #expect(reader.putSecret(name: "denied", value: "never-written").status != 0)
    #expect(await reader.allowForward(host: "127.0.0.1", port: 22) == false)
    #expect(await reader.sessions().isEmpty)
    #expect(await reader.management().servers.isEmpty)
    #expect(await operatorUser.execute("app restart other/worker").status != 0)
    // The identity object is not an authorization snapshot: demotion/revocation
    // must immediately apply to commands from already-connected SSH clients.
    _ = try local.identities.set(name: "operator", role: "viewer", key: nil, modules: ["sample/worker"])
    #expect(await operatorUser.execute("app start sample/worker").text.contains("Permission denied"))
    _ = try local.identities.set(name: "reader", role: "viewer", key: nil, modules: [], revoke: true)
    #expect(!reader.isAuthorized())
    #expect(await reader.execute("status").status != 0)
    await runtime.shutdown()
}

@Test func identityPolicyPreservesBootstrapAdminAndDoesNotReimportRevokedKeys() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = KilnIdentityStore(directory: directory)
    try store.bootstrap(name: "admin", keys: [identityKey])
    #expect(throws: (any Error).self) { _ = try store.set(name: "admin", role: "viewer", key: nil, modules: []) }
    #expect(throws: (any Error).self) { _ = try store.set(name: "admin", role: "admin", key: nil, modules: [], revoke: true) }
    _ = try store.set(name: "backup", role: "admin", key: identityKey, modules: [])
    _ = try store.set(name: "admin", role: "admin", key: nil, modules: [], revoke: true)
    try store.bootstrap(name: "admin", keys: [identityKey])
    #expect(throws: (any Error).self) { _ = try store.resolve(KilnPrincipal(name: "admin", publicKey: identityKey)) }
    #expect(try store.resolve(KilnPrincipal(name: "backup", publicKey: identityKey)).role == "admin")
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("identities.json").path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let savedPolicy = try Data(contentsOf: directory.appendingPathComponent("identities.json"))
    try FileManager.default.removeItem(at: directory.appendingPathComponent("identities.json"))
    #expect(throws: (any Error).self) { try store.bootstrap(name: "admin", keys: [identityKey]) }
    try savedPolicy.write(to: directory.appendingPathComponent("identities.json"))
    // A corrupt policy fails closed; bootstrap never replaces it with old keys.
    try Data("broken".utf8).write(to: directory.appendingPathComponent("identities.json"))
    #expect(throws: (any Error).self) { try store.bootstrap(name: "admin", keys: [identityKey]) }
}

@Test func auditExcludesCommandArgumentsAndSecrets() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try KilnRuntime(stateDirectory: directory)
    let commands = KilnCommands(runtime: runtime)
    _ = await commands.execute("ai ask PRIVATE_PROMPT_MUST_NOT_APPEAR")
    _ = await commands.execute("ai configure https://example.invalid/v1 model vault-name")
    let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("audit"), includingPropertiesForKeys: nil)
    #expect(!files.isEmpty)
    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("PRIVATE_PROMPT_MUST_NOT_APPEAR"))
        #expect(text.contains("local-console"))
    }
    await runtime.shutdown()
}

@Test func auditCapacityBlocksChangesButKeepsReadsAndDenialsBounded() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try KilnRuntime(stateDirectory: directory)
    let commands = KilnCommands(runtime: runtime)
    let audit = directory.appendingPathComponent("audit")
    try FileManager.default.createDirectory(at: audit, withIntermediateDirectories: true)
    // Existing retained evidence consumes the configured file budget; the writer
    // must refuse another intent instead of deleting records to run a mutation.
    for number in 0..<4096 { #expect(FileManager.default.createFile(atPath: audit.appendingPathComponent("retained-\(number).json").path, contents: Data())) }
    #expect(await commands.execute("status").status == 0)
    #expect(await commands.execute("app list").status == 0)
    let mutation = await commands.execute("app start default/missing")
    #expect(mutation.status != 0)
    #expect(mutation.text.contains("Audit capacity reached"))
    #expect(!mutation.text.contains("Unknown application"))
    for _ in 0..<260 { try commands.identities.audit(nil, verb: "app stop", outcome: "denied") }
    #expect(try FileManager.default.contentsOfDirectory(atPath: audit.appendingPathComponent("denied").path).count == 256)
    #expect(try FileManager.default.contentsOfDirectory(at: audit, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.count == 4096)
    await runtime.shutdown()
}
