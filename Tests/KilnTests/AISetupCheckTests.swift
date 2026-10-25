import Foundation
import Testing
import Crypto
import KilnKit
import KilnRuntime
import KilnCommands
import KilnTerminal
@testable import KilnAI

private let setupKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
private func setupRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return root
}

@Test func setupCheckReportsMissingConfigurationAndRemainsAdminOnly() async throws {
    let root = try setupRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try KilnRuntime(stateDirectory: root.appendingPathComponent("state"))
    let commands = KilnCommands(runtime: runtime)
    let missing = await commands.execute("ai check")
    #expect(missing.status == 2 && missing.text.contains("active profile missing or invalid"))
    #expect(!FileManager.default.fileExists(atPath: runtime.stateDirectory.appendingPathComponent("chatgpt-accounts").path))
    try commands.bootstrapIdentity(username: "admin", keys: [setupKey])
    _ = try commands.identities.set(name: "reader", role: "viewer", key: setupKey, modules: [])
    let reader = commands.forIdentity(name: "reader", publicKey: setupKey)
    let denied = await reader.execute("ai check")
    #expect(denied.status != 0 && denied.text.contains("Permission denied"))
    #expect(!denied.text.contains("active profile"))
    _ = try commands.identities.set(name: "reader", role: "viewer", key: nil, modules: [], revoke: true)
    #expect(await reader.execute("ai check").status != 0)
    await runtime.shutdown()
}

@Test func setupCheckValidatesAPIGrantWithoutReturningCredentialsOrChangingState() async throws {
    let root = try setupRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try KilnRuntime(stateDirectory: root.appendingPathComponent("state"))
    let commands = KilnCommands(runtime: runtime)
    #expect(await commands.execute("ai profile add api erebine https://provider.invalid/v1 SetupModel setup-ref").status == 0)
    #expect(await commands.execute("ai profile use api --new-context").status == 0)
    #expect(await commands.execute("ai check").status == 2)
    _ = try runtime.vault.initialize(keyFile: root.appendingPathComponent("master.key"))
    _ = try runtime.vault.put("setup-ref", value: "PRIVATE_SETUP_VALUE")
    #expect(await commands.execute("ai check").status == 2)
    _ = try runtime.vault.grant("setup-ref", to: "kiln/ai-api")
    let config = try Data(contentsOf: runtime.stateDirectory.appendingPathComponent("ai.json"))
    let ciphertext = try Data(contentsOf: runtime.stateDirectory.appendingPathComponent("vault.enc"))
    let checked = await commands.execute("ai check")
    #expect(checked.status == 0 && checked.text.contains("Local setup checks passed"))
    #expect(checked.text.contains("inference were not tested"))
    for privateText in ["PRIVATE_SETUP_VALUE", "setup-ref", "provider.invalid"] { #expect(!checked.text.contains(privateText)) }
    #expect(try Data(contentsOf: runtime.stateDirectory.appendingPathComponent("ai.json")) == config)
    #expect(try Data(contentsOf: runtime.stateDirectory.appendingPathComponent("vault.enc")) == ciphertext)
    _ = try runtime.vault.revoke("setup-ref", from: "kiln/ai-api")
    #expect(await commands.execute("ai check").status == 2)
    await runtime.shutdown()
}

@Test func localOllamaSetupCheckUsesTheTransportProxyPolicy() throws {
    let config = AIConfiguration(baseURL: "http://127.0.0.1:11434", model: "local", secret: "", provider: .ollama)
    try config.validateRuntimeEnvironment([:])
    try config.validateRuntimeEnvironment(["HTTP_PROXY": ""])
    for key in ["HTTP_PROXY", "https_proxy", "All_PrOxY"] {
        #expect(throws: (any Error).self) { try config.validateRuntimeEnvironment([key: "http://fixture.invalid", "NO_PROXY": "*"]) }
    }
}

@Test func chatSetupCheckShortcutStaysOnTheLocalCommandPath() {
    var ui = KilnTerminal(); _ = ui.handle(.text("7"))
    _ = ui.handle(.text("/check"))
    #expect(ui.handle(.enter) == [.command("ai check")])
}

@Test func chatGPTLocalCredentialCheckNeverRenewsAndRechecksOwnershipAndSignOut() async throws {
    let root = try setupRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try KilnRuntime(stateDirectory: root.appendingPathComponent("state"))
    _ = try runtime.vault.initialize(keyFile: root.appendingPathComponent("master.key"))
    let directory = runtime.stateDirectory.appendingPathComponent("chatgpt-accounts")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let id = UUID().uuidString.lowercased()
    let owner = "local-console:" + SHA256.hash(data: Data("local-console".utf8)).map { String(format: "%02x", $0) }.joined()
    let file = directory.appendingPathComponent("chatgpt-accounts.json")
    func metadata(_ signedIn: Bool) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["hostID": "urn:uuid:" + root.lastPathComponent.lowercased(), "accounts": [["id": id, "owner": owner, "subject": "private-subject", "clientID": "oaiapp_fixture", "signedIn": signedIn, "planEnabled": true]]])
    }
    try KilnStateFile.write(metadata(true), to: file)
    let service = try ChatGPTSignIn(directory: directory, vault: runtime.vault, http: { _ in
        Issue.record("Local credential check attempted HTTP")
        throw AIError.message("Unexpected HTTP")
    })
    let saved = ChatGPTSignIn.Tokens(accessToken: "PRIVATE_ACCESS", refreshToken: "PRIVATE_REFRESH", idToken: "PRIVATE_IDENTITY", scopes: ["chatgpt.tokens.use.direct"], expiresAt: Date().addingTimeInterval(-60))
    _ = try runtime.vault.put("chatgpt-" + id, value: String(decoding: JSONEncoder().encode(saved), as: UTF8.self))
    _ = try runtime.vault.grant("chatgpt-" + id, to: "kiln/chatgpt-" + id)
    let ciphertext = try Data(contentsOf: runtime.stateDirectory.appendingPathComponent("vault.enc"))
    #expect(try await service.localCredentialStatus(account: id, owner: owner).contains("renewal will be required"))
    do { _ = try await service.localCredentialStatus(account: id, owner: "other"); Issue.record("Cross-owner inspection allowed") } catch {}
    let config = AIConfiguration(baseURL: "https://api.openai.com/v1", model: "AccountModel", secret: id, provider: .chatgpt, profile: "plan")
    try KilnStateFile.write(JSONEncoder().encode(config), to: runtime.stateDirectory.appendingPathComponent("ai.json"))
    let checked = await KilnCommands(runtime: runtime).execute("ai check")
    #expect(checked.status == 0 && checked.text.contains("renewal will be required"))
    for privateText in [id, owner, "PRIVATE_ACCESS", "PRIVATE_REFRESH", "PRIVATE_IDENTITY", "private-subject"] { #expect(!checked.text.contains(privateText)) }
    #expect(try Data(contentsOf: runtime.stateDirectory.appendingPathComponent("vault.enc")) == ciphertext)
    try KilnStateFile.write(metadata(false), to: file)
    do { _ = try await service.localCredentialStatus(account: id, owner: owner); Issue.record("Stale sign-in accepted") } catch {}
    #expect(await KilnCommands(runtime: runtime).execute("ai check").status == 2)
    await runtime.shutdown()
}
