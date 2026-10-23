import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import KilnKit
import KilnRuntime
@testable import KilnCommands
import KilnSSH
@testable import KilnAI

private final class RetryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

/// Installed only in the explicitly opted-in test session. Production provider
/// configuration and HTTPS validation stay unchanged; no real provider is called.
private final class SSHRetryProtocol: URLProtocol {
    static let counter = RetryCounter()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "ssh-retry.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let first = Self.counter.next() == 1
        let response = HTTPURLResponse(url: request.url!, statusCode: first ? 429 : 200,
            httpVersion: nil, headerFields: first ? ["Retry-After": "5"] : ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = first ? "{\"error\":{\"code\":\"capacity_exceeded\"}}" : "data: {\"choices\":[{\"delta\":{\"content\":\"Retry fixture recovered.\"}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func sshRetryAcceptance() async throws {
    guard let path = ProcessInfo.processInfo.environment["KILN_SSH_RETRY_STATE"],
          let port = Int(ProcessInfo.processInfo.environment["KILN_SSH_RETRY_PORT"] ?? "") else { return }
    let root = URL(fileURLWithPath: path)
    let state = root.appendingPathComponent("state")
    let runtime = try KilnRuntime(stateDirectory: state)
    _ = try runtime.vault.initialize(keyFile: root.appendingPathComponent("vault.key"))
    _ = try runtime.vault.put("fixture", value: "disposable-not-a-credential")
    _ = try runtime.vault.grant("fixture", to: "kiln/ai")
    let configuration = AIConfiguration(baseURL: "https://ssh-retry.invalid/v1", model: "fixture", secret: "fixture")
    try KilnStateFile.write(JSONEncoder().encode(configuration), to: state.appendingPathComponent("ai.json"))
    let assistant = KilnAssistant(streamingCompletion: { _, _, _, _, emit in
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [SSHRetryProtocol.self]
        return try await ProviderRetry.run(emit: emit) {
            try await ErebineClient().streamAttempt(request: URLRequest(url: URL(string: "https://ssh-retry.invalid/v1")!), configuration: options, emit: emit)
        }
    })
    let commands = KilnCommands(runtime: runtime, assistant: assistant)
    let server = try await KilnSSHServer.start(host: "127.0.0.1", port: port, username: "admin",
        authorizedKeys: root.appendingPathComponent("admin.pub"), stateDirectory: state, commands: commands)
    do {
        try Data().write(to: root.appendingPathComponent("ready"))
        let deadline = Date().addingTimeInterval(40)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("done").path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("passed").path))
        await server.stop(); await runtime.shutdown()
    } catch {
        await server.stop(); await runtime.shutdown(); throw error
    }
}
