import Foundation
import Testing
import KilnKit
import KilnRuntime
import KilnCommands

private let providerCommandKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

@Test func providerCommandsListWithoutCredentialsAndGateHeadlessBeforeInspection() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try KilnRuntime(stateDirectory: directory)
    let local = KilnCommands(runtime: runtime)
    try local.bootstrapIdentity(username: "admin", keys: [providerCommandKey])
    _ = try local.identities.set(name: "viewer", role: "viewer", key: providerCommandKey, modules: [])
    _ = try local.identities.set(name: "operator", role: "operator", key: providerCommandKey, modules: [])
    let viewer = local.forIdentity(name: "viewer", publicKey: providerCommandKey)
    let operatorUser = local.forIdentity(name: "operator", publicKey: providerCommandKey)
    let admin = local.forIdentity(name: "admin", publicKey: providerCommandKey)
    for commands in [viewer, operatorUser, admin] {
        let listing = await commands.execute("ai providers")
        #expect(listing.status == 0)
        for provider in ["erebine", "ollama", "openai", "anthropic", "grok", "deepseek"] {
            #expect(listing.text.contains(provider))
        }
        #expect(listing.text.contains("https://api.anthropic.com/v1"))
        #expect(listing.text.contains("https://api.x.ai/v1"))
    }
    for commands in [viewer, operatorUser] {
        for command in ["ai headless", "ai headless ask /nonexistent/grok fixture missing PRIVATE_PROVIDER_PROMPT"] {
            let denied = await commands.execute(command)
            #expect(denied.status != 0)
            #expect(denied.text.contains("Permission denied"))
            #expect(!denied.text.contains("executable path"))
            #expect(!denied.text.contains("PRIVATE_PROVIDER_PROMPT"))
        }
    }
    let missingArguments = await admin.execute("ai headless")
    #expect(missingArguments.status != 0)
    #expect(missingArguments.text.contains("Use ai headless ask"))
    let relative = await admin.execute("ai headless ask relative-grok fixture missing PRIVATE_PROVIDER_PROMPT")
    #expect(relative.status != 0)
    #expect(relative.text.contains("absolute executable path"))
    // No configured Vault, executable launch or inference is needed for validation.
    _ = try local.identities.set(name: "viewer", role: "viewer", key: nil, modules: [], revoke: true)
    #expect(await viewer.execute("ai providers").status != 0)
    let audit = directory.appendingPathComponent("audit")
    for folder in [audit, audit.appendingPathComponent("denied")] {
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("PRIVATE_PROVIDER_PROMPT"))
        }
    }
    await runtime.shutdown()
}
