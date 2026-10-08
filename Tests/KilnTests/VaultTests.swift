import Foundation
import Testing
@testable import KilnVault
@testable import KilnKit
import KilnRuntime

private func fixture() throws -> (URL, KilnVault, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-vault-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let key = root.appendingPathComponent("master.key")
    let vault = KilnVault(directory: root.appendingPathComponent("state"))
    _ = try vault.initialize(keyFile: key)
    return (root, vault, key)
}

@Test func vaultEncryptsPersistsAndEnforcesExplicitGrants() throws {
    let (root, vault, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let secret = "test-only-" + UUID().uuidString
    _ = try vault.put("mail-token", value: secret)
    _ = try vault.put("other-token", value: "another-test-value")
    #expect(!String(decoding: try Data(contentsOf: vault.directory.appendingPathComponent("vault.enc")), as: UTF8.self).contains(secret))
    #expect(throws: (any Error).self) { try vault.environment(for: "app/mail", bindings: ["TOKEN": "mail-token"]) }
    _ = try vault.grant("mail-token", to: "app/mail")
    let reopened = KilnVault(directory: vault.directory)
    #expect(try reopened.environment(for: "app/mail", bindings: ["TOKEN": "mail-token"]) == ["TOKEN": secret])
    #expect(try reopened.environment(for: "app/mail", bindings: [:]).isEmpty)
    #expect(throws: (any Error).self) { try reopened.environment(for: "other/mail", bindings: ["TOKEN": "mail-token"]) }
    #expect(throws: (any Error).self) { try reopened.environment(for: "app/mail", bindings: ["TOKEN": "other-token"]) }
    #expect(throws: (any Error).self) { try reopened.delete("mail-token") }
    _ = try reopened.put("mail-token", value: "rotated-test-value")
    #expect(try reopened.environment(for: "app/mail", bindings: ["TOKEN": "mail-token"])["TOKEN"] == "rotated-test-value")
    _ = try reopened.revoke("mail-token", from: "app/mail")
    #expect(throws: (any Error).self) { try reopened.environment(for: "app/mail", bindings: ["TOKEN": "mail-token"]) }
    _ = try reopened.delete("mail-token")
    #expect(!(try reopened.list()).contains("mail-token"))
}

@Test func vaultRejectsTamperingMissingKeysAndLoosePermissions() throws {
    let (root, vault, key) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try vault.put("token", value: "test-value")
    let path = vault.directory.appendingPathComponent("vault.enc")
    var bytes = try Data(contentsOf: path); bytes[bytes.count - 1] ^= 1
    try bytes.write(to: path)
    #expect(throws: (any Error).self) { try vault.list() }
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: key.path)
    #expect(throws: (any Error).self) { try vault.list() }
    try FileManager.default.removeItem(at: key)
    #expect(throws: (any Error).self) { try vault.list() }
    #expect(throws: (any Error).self) { try vault.initialize(keyFile: root.appendingPathComponent("replacement")) }
}

@Test func moduleCannotStartWithoutVaultGrant() async throws {
    let (root, vault, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try vault.put("credential", value: "test-only-value")
    let runtime = try KilnRuntime(stateDirectory: vault.directory)
    let manifest = ApplicationManifest(application: "sample", name: "worker", version: "26.10.07.2", executable: "/bin/sleep", arguments: ["60"], secrets: ["API_TOKEN": "credential"])
    let path = root.appendingPathComponent("module.json")
    try JSONEncoder().encode(manifest).write(to: path)
    _ = try await runtime.install(path: path.path)
    do { _ = try await runtime.start("sample/worker"); Issue.record("Started without grant") } catch {}
    #expect(await runtime.snapshot().first?.pid == nil)
    _ = try vault.grant("credential", to: "sample/worker")
    _ = try await runtime.start("sample/worker")
    #expect(await runtime.snapshot().first?.pid != nil)
    _ = try await runtime.stop("sample/worker")
    _ = try vault.revoke("credential", from: "sample/worker")
    do { _ = try await runtime.start("sample/worker"); Issue.record("Started after revocation") } catch {}
    await runtime.shutdown()
}

@Test func vaultBindingsRejectReservedEnvironmentNames() throws {
    for name in ["PATH", "DYLD_INSERT_LIBRARIES", "KILN_PORT", "LD_PRELOAD", "bad-name"] {
        #expect(throws: (any Error).self) {
            try ApplicationManifest(name: "worker", version: "1", executable: "/bin/echo", secrets: [name: "token"]).validate()
        }
    }
}

@Test func vaultUncertainInitializationPreservesCommittedKeyAndStore() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("state"), key = root.appendingPathComponent("master.key")
    let interrupted = KilnVault(directory: directory) { bytes, path in
        try KilnStateFile.write(bytes, to: path)
        if path.lastPathComponent == "vault-config.json" { throw KilnStateFile.CommitUncertain() }
    }
    #expect(throws: (any Error).self) { try interrupted.initialize(keyFile: key) }
    #expect(try Data(contentsOf: key).count == 32)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("vault.enc").path))
    let reopened = KilnVault(directory: directory)
    #expect(try reopened.list() == "Vault is empty.")
    _ = try reopened.put("recovered", value: "test-only")
    #expect(try reopened.list() == "recovered")
    #expect(throws: (any Error).self) { try reopened.initialize(keyFile: root.appendingPathComponent("replacement.key")) }
}

@Test func vaultRejectsUnprotectedKeyParentAndSubstitutedFiles() throws {
    let (root, vault, key) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let publicParent = root.appendingPathComponent("writable")
    try FileManager.default.createDirectory(at: publicParent, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: publicParent.path)
    let other = KilnVault(directory: root.appendingPathComponent("other-state"))
    #expect(throws: (any Error).self) { try other.initialize(keyFile: publicParent.appendingPathComponent("key")) }
    #expect(!FileManager.default.fileExists(atPath: publicParent.appendingPathComponent("key").path))
    let actual = root.appendingPathComponent("preserved.key")
    try FileManager.default.moveItem(at: key, to: actual)
    try FileManager.default.createSymbolicLink(at: key, withDestinationURL: actual)
    #expect(throws: (any Error).self) { try vault.list() }
    try FileManager.default.removeItem(at: key)
    try FileManager.default.moveItem(at: actual, to: key)
    #expect(try vault.list() == "Vault is empty.")
    let encrypted = vault.directory.appendingPathComponent("vault.enc")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: encrypted.path)
    #expect(throws: (any Error).self) { try vault.list() }
}

@Test func vaultRejectsOversizedStoreBeforeDecoding() throws {
    let (root, vault, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try FileHandle(forWritingTo: vault.directory.appendingPathComponent("vault.enc"))
    try file.truncate(atOffset: 16_777_217); try file.close()
    #expect(throws: (any Error).self) { try vault.list() }
}
