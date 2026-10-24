import Foundation
import Testing
import KilnAI
import KilnKit
import KilnRuntime
import KilnTerminal
@testable import KilnCommands

private func helpChat() -> KilnTerminal {
    var terminal = KilnTerminal()
    _ = terminal.handle(.text("7"))
    return terminal
}

@Test func chatHelpUsesLocalReference() {
    var terminal = helpChat()
    _ = terminal.handle(.text("/help"))
    #expect(terminal.handle(.enter) == [.command("ai chat-help")])
    terminal.finish(text: "Chat commands / local reference", status: 0)
    #expect(terminal.chatVisible && !terminal.busy)
    #expect(terminal.render().contains("Chat commands / local reference"))
    #expect(!terminal.render().contains("KILN /"))
}

@Test func incompleteChatCommandsStayLocalAndAllowTheNextRequest() {
    for command in ["/task", "/watch", "/cancel", "/recover", "/approve", "/deny"] {
        var terminal = helpChat()
        _ = terminal.handle(.text(command + "   "))
        #expect(terminal.handle(.enter).isEmpty)
        #expect(terminal.chatVisible && !terminal.busy)
        #expect(terminal.render().contains("Usage: " + command))
        _ = terminal.handle(.text("ordinary follow-up"))
        #expect(terminal.handle(.enter) == [.command("ai ask \"ordinary follow-up\"")])
    }
}

@Test func chatCommandGuardPreservesArgumentsAndPathPrompts() {
    for (input, expected) in [("/approve proposal-1", "ai approve proposal-1"), ("/task inspect worker", "ai task new \"inspect worker\""), ("/tmp/example.swift needs review", "ai ask \"/tmp/example.swift needs review\""), ("/helper example", "ai ask \"/helper example\"")] {
        var terminal = helpChat()
        _ = terminal.handle(.text(input))
        #expect(terminal.handle(.enter) == [.command(expected)])
    }
}

@Test func chatReferenceWorksForViewerWithoutProviderConfigurationOrInference() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let assistant = KilnAssistant { _, _, _, _ in
        Issue.record("Local help attempted provider inference")
        return AIMessage(role: "assistant", content: "unexpected")
    }
    let runtime = try KilnRuntime(stateDirectory: directory)
    let commands = KilnCommands(runtime: runtime, assistant: assistant)
    let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    try commands.bootstrapIdentity(username: "admin", keys: [key])
    _ = try commands.identities.set(name: "reader", role: "viewer", key: key, modules: [])
    let reader = commands.forIdentity(name: "reader", publicKey: key)
    let result = await reader.execute("ai chat-help", sessionID: "help")
    #expect(result.status == 0 && result.text.contains("/approve PROPOSAL-ID"))
    #expect(result.text.contains("Backtick opens commands"))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("ai.json").path))
    #expect(await reader.execute("ai context", sessionID: "help").text.contains("Completed turns: 0"))
    _ = try commands.identities.set(name: "reader", role: "viewer", key: nil, modules: [], revoke: true)
    #expect(await reader.execute("ai chat-help", sessionID: "help").status != 0)
    await runtime.shutdown()
}
