import Foundation
import Testing
import KilnKit
import KilnAI
import KilnRuntime
import KilnCommands
import KilnTerminal

private let selectionKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

@Test func chatProviderCommandsRequireExplicitContextResetAndStayLocal() {
    for (input, expected) in [("/provider", "ai status"), ("/providers", "ai profile list --details"), ("/provider work --new-context", "ai profile use \"work\" --new-context")] {
        var ui = KilnTerminal(); _ = ui.handle(.text("7"))
        _ = ui.handle(.text(input))
        #expect(ui.handle(.enter) == [.command(expected)])
    }
    for input in ["/provider work", "/provider work --wrong", "/provider work --new-context extra", "/provider\twork"] {
        var ui = KilnTerminal(); _ = ui.handle(.text("7"))
        _ = ui.handle(.text(input))
        #expect(ui.handle(.enter).isEmpty && !ui.busy && ui.chatVisible)
        #expect(ui.render().contains("Use /provider NAME --new-context"))
    }
    var ui = KilnTerminal(); _ = ui.handle(.text("7"))
    _ = ui.handle(.text("/provider/settings.json needs review"))
    #expect(ui.handle(.enter) == [.command("ai ask \"/provider/settings.json needs review\"")])
}

@Test func detailedProfileInventoryReadsOnlySafeMetadataAndPreservesSelection() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try KilnRuntime(stateDirectory: directory)
    let commands = KilnCommands(runtime: runtime)
    #expect(await commands.execute("ai profile add hosted erebine https://provider.invalid/v1 RemoteModel PRIVATE_REFERENCE").status == 0)
    #expect(await commands.execute("ai profile add local ollama http://127.0.0.1:11434 LocalModel").status == 0)
    #expect(await commands.execute("ai profile use hosted --new-context").status == 0)
    let selected = try Data(contentsOf: directory.appendingPathComponent("ai.json"))
    let profiles = directory.appendingPathComponent("ai-profiles")
    let account = UUID().uuidString
    let chatgpt = AIConfiguration(baseURL: "https://api.openai.com/v1", model: "AccountModel", secret: account, provider: .chatgpt, profile: "plan")
    try JSONEncoder().encode(chatgpt).write(to: profiles.appendingPathComponent("plan.json"))
    #expect(await commands.execute("ai profile list").text == "hosted\nlocal\nplan")
    try Data("NEVER_REFLECT_CONFIG".utf8).write(to: profiles.appendingPathComponent("broken.json"))
    try Data(repeating: 97, count: 16385).write(to: profiles.appendingPathComponent("oversized.json"))
    try FileManager.default.createSymbolicLink(at: profiles.appendingPathComponent("linked.json"), withDestinationURL: profiles.appendingPathComponent("local.json"))
    let hostile = AIConfiguration(baseURL: "http://127.0.0.1:11434", model: "\u{1b}[2J", secret: "", provider: .ollama, profile: "hostile")
    try JSONEncoder().encode(hostile).write(to: profiles.appendingPathComponent("hostile.json"))
    let inventory = await commands.execute("ai profile list --details")
    #expect(inventory.status == 0)
    #expect(inventory.text.contains("Active: hosted / Erebine / RemoteModel"))
    #expect(inventory.text.contains("local / Ollama / LocalModel / Ollama daemon"))
    #expect(inventory.text.contains("plan / ChatGPT / AccountModel / ChatGPT plan"))
    for name in ["broken", "oversized", "linked"] { #expect(inventory.text.contains(name + " / unavailable")) }
    #expect(inventory.text.contains("hostile / Ollama / invalid"))
    for value in [account, "PRIVATE_REFERENCE", "provider.invalid", "NEVER_REFLECT_CONFIG", "\u{1b}"] { #expect(!inventory.text.contains(value)) }
    #expect(try Data(contentsOf: directory.appendingPathComponent("ai.json")) == selected)
    #expect(await commands.execute("ai context").text.contains("Completed turns: 0"))
    await runtime.shutdown()
}

@Test func savedProfileInventoryAndSelectionRemainAdministratorOnly() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try KilnRuntime(stateDirectory: directory)
    let commands = KilnCommands(runtime: runtime)
    try commands.bootstrapIdentity(username: "admin", keys: [selectionKey])
    _ = try commands.identities.set(name: "reader", role: "viewer", key: selectionKey, modules: [])
    let admin = commands.forIdentity(name: "admin", publicKey: selectionKey)
    let reader = commands.forIdentity(name: "reader", publicKey: selectionKey)
    #expect(await admin.execute("ai profile add local ollama http://127.0.0.1:11434 LocalModel").status == 0)
    #expect(await reader.execute("ai profile list --details").status != 0)
    #expect(await reader.execute("ai profile use local --new-context").status != 0)
    #expect(await admin.execute("ai profile use local --new-context").status == 0)
    #expect(await reader.execute("ai status").text.contains("LocalModel"))
    _ = try commands.identities.set(name: "reader", role: "viewer", key: nil, modules: [], revoke: true)
    #expect(await reader.execute("ai status").status != 0)
    await runtime.shutdown()
}
