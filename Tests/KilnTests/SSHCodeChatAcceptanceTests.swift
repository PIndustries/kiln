import Foundation
import Testing
import KilnKit
import KilnRuntime
import KilnSSH
@testable import KilnAI
@testable import KilnCommands

/// Opt-in real SSH acceptance. The assistant is injected only in the test process.
@Test func sshCodeChatAcceptance() async throws {
    guard let path = ProcessInfo.processInfo.environment["KILN_CODE_CHAT_STATE"],
          let port = Int(ProcessInfo.processInfo.environment["KILN_CODE_CHAT_PORT"] ?? "") else { return }
    let root = URL(fileURLWithPath:path), state = root.appendingPathComponent("state")
    let runtime = try KilnRuntime(stateDirectory:state)
    let configuration = AIConfiguration(baseURL:"http://127.0.0.1:11434",model:"fixture",secret:"",provider:.ollama)
    try KilnStateFile.write(JSONEncoder().encode(configuration),to:state.appendingPathComponent("ai.json"))
    let assistant = KilnAssistant(streamingCompletion: { _, _, messages, _, emit in
        let prompt = messages.last(where: { $0.role == "user" })?.content ?? ""
        try KilnStateFile.write(Data(prompt.utf8),to:root.appendingPathComponent("last-prompt"))
        let label = String(prompt.split(separator:"\n").first ?? "unknown")
        emit(.answer("Streaming: " + label))
        for _ in 0..<60 { try await Task.sleep(for:.milliseconds(100)); try Task.checkCancellation() }
        return AIMessage(role:"assistant",content:"Complete: " + label)
    })
    let commands = KilnCommands(runtime:runtime,assistant:assistant)
    let server = try await KilnSSHServer.start(host:"127.0.0.1",port:port,username:"admin",authorizedKeys:root.appendingPathComponent("admin.pub"),stateDirectory:state,commands:commands)
    do {
        try Data().write(to:root.appendingPathComponent("ready"))
        let deadline = Date().addingTimeInterval(150)
        while !FileManager.default.fileExists(atPath:root.appendingPathComponent("done").path), Date() < deadline {
            try await Task.sleep(for:.milliseconds(100))
        }
        #expect(FileManager.default.fileExists(atPath:root.appendingPathComponent("passed").path))
        await server.stop(); await runtime.shutdown()
    } catch { await server.stop(); await runtime.shutdown(); throw error }
}
