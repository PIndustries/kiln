import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import KilnKit
import KilnTerminal
@testable import KilnAI

/// No network, credentials, or provider account. Exercise the native URLSession
/// delegate, SSE decoder and real terminal renderer with separated body deliveries.
private final class ProtocolReference: @unchecked Sendable {
    let value: URLProtocol
    init(_ value: URLProtocol) { self.value = value }
}

private final class DelayedTerminalProtocol: URLProtocol {
    private let lock = NSLock()
    private var delivery: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "terminal-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // FoundationNetworking explicitly marks URLProtocol non-Sendable. The
        // holder confines callbacks to this one delivery task; stopLoading only
        // cancels its lock-protected handle.
        let reference = ProtocolReference(self)
        let task = Task { @Sendable [reference] in
            let source = reference.value
            let response = HTTPURLResponse(url: source.request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            source.client?.urlProtocol(source, didReceive: response, cacheStoragePolicy: .notAllowed)
            let chunks = source.request.url!.path == "/cancel" ? Array(repeating: "still working ", count: 100) : ["First ", "second ", "third ", "fourth ", "complete."]
            do {
                for chunk in chunks {
                    try await Task.sleep(for: .milliseconds(40))
                    try Task.checkCancellation()
                    let object: [String: Any] = ["choices": [["delta": ["content": chunk]]]]
                    let bytes = try JSONSerialization.data(withJSONObject: object)
                    source.client?.urlProtocol(source, didLoad: Data("data: ".utf8) + bytes + Data("\n\n".utf8))
                }
                source.client?.urlProtocol(source, didLoad: Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8))
                source.client?.urlProtocolDidFinishLoading(source)
            } catch { /* URLSession cancellation owns completion. */ }
        }
        lock.withLock { delivery = task }
    }
    override func stopLoading() { lock.withLock { delivery?.cancel() } }
}

private final class TerminalFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var terminal: KilnTerminal
    private var frames: [String] = []
    init() {
        var terminal = KilnTerminal(); terminal.resize(width: 120, height: 30)
        _ = terminal.handle(.text("7")); _ = terminal.handle(.text("fixture")); _ = terminal.handle(.enter)
        self.terminal = terminal
    }
    func receive(_ event: AIProgress) {
        lock.withLock { terminal.progress(event); terminal.tick(); frames.append(terminal.render()) }
    }
    func snapshot() -> [String] { lock.withLock { frames } }
    func workspace(_ value: AIWorkspaceSnapshot) { lock.withLock { terminal.updateAIWorkspace(value) } }
    func current() -> String { lock.withLock { terminal.render() } }
    func handle(_ key: TerminalKey) -> [TerminalEffect] { lock.withLock { terminal.handle(key) } }

    func finish(_ text: String, status: Int = 0) -> String {
        lock.withLock { terminal.finish(text: text, status: status); return terminal.render() }
    }
}
private func fixtureOptions() -> URLSessionConfiguration {
    let options = URLSessionConfiguration.ephemeral
    options.protocolClasses = [DelayedTerminalProtocol.self]
    return options
}

@Test func offlineDelayedSSEProducesPartialTerminalFramesBeforeCompletion() async throws {
    let frames = TerminalFrames()
    let message = try await ErebineClient().streamAttempt(request: URLRequest(url: URL(string: "https://terminal-fixture.invalid/complete")!), configuration: fixtureOptions(), emit: { frames.receive($0) })
    let snapshots = frames.snapshot()
    #expect(snapshots.count >= 5)
    #expect(Set(snapshots).count >= 5)
    #expect(snapshots.first?.contains("First") == true)
    #expect(snapshots.first?.contains("complete.") == false)
    #expect(snapshots.dropLast().allSatisfy { $0.contains("[streaming]") })
    #expect(message.content == "First second third fourth complete.")
    let final = frames.finish(message.content!)
    #expect(final.contains("[ready]"))
    #expect(final.components(separatedBy: "First second third fourth complete.").count == 2, "Final answer must replace partial output, not duplicate it")
}

@Test func offlineStreamCancellationStopsDeliveryAndNextRequestWorks() async throws {
    let frames = TerminalFrames()
    let task = Task {
        try await ErebineClient().streamAttempt(request: URLRequest(url: URL(string: "https://terminal-fixture.invalid/cancel")!), configuration: fixtureOptions(), emit: { frames.receive($0) })
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while frames.snapshot().count < 2 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(frames.snapshot().count >= 2)
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled stream unexpectedly completed") }
    catch { #expect(error is CancellationError) }
    let count = frames.snapshot().count
    try await Task.sleep(for: .milliseconds(150))
    #expect(frames.snapshot().count == count, "No late terminal progress after cancellation returns")
    #expect(frames.finish("Cancelled", status: 1).contains("[ready]"))
    let replacement = try await ErebineClient().streamAttempt(request: URLRequest(url: URL(string: "https://terminal-fixture.invalid/complete")!), configuration: fixtureOptions(), emit: { _ in })
    #expect(replacement.content?.hasSuffix("complete.") == true)
}

@Test func offlineSidebarRefreshResizeAndRoleRemovalDoNotLeaveActionableStaleData() throws {
    let id = UUID().uuidString
    var ui = KilnTerminal(); ui.resize(width: 150, height: 30); _ = ui.handle(.text("7"))
    ui.updateManagement(ManagementSnapshot(access: "admin / admin"))
    ui.updateAIWorkspace(AIWorkspaceSnapshot(proposals: [AIProposalSnapshot(id: id, operation: "restart", module: "fixture/api", expires: Date().addingTimeInterval(30))], tasks: [AITaskSnapshot(id: "task", prompt: "offline investigation", status: "running")]))
    #expect(ui.render().contains("TASK / running"))
    ui.updateAIWorkspace(AIWorkspaceSnapshot(proposals: [AIProposalSnapshot(id: id, operation: "restart", module: "fixture/api", expires: Date().addingTimeInterval(30))], tasks: [AITaskSnapshot(id: "task", prompt: "offline investigation", status: "completed")]))
    #expect(ui.render().contains("TASK / completed"))
    #expect(!ui.render().contains("TASK / running"))
    _ = ui.handle(.tab); _ = ui.handle(.enter)
    #expect(ui.render().contains("app restart fixture/api"))
    ui.resize(width: 80, height: 24)
    #expect(ui.render().contains("app restart fixture/api"))
    ui.updateManagement(ManagementSnapshot(error: "Administrator role required", access: "admin / viewer"))
    ui.updateAIWorkspace(AIWorkspaceSnapshot(error: "Identity revoked or unauthorized"))
    #expect(ui.handle(.enter).isEmpty)
    let revoked = ui.render()
    #expect(!revoked.contains("fixture/api") && !revoked.contains("offline investigation"))
    let ansi = try NSRegularExpression(pattern: "\u{1b}\\[[0-9;?]*[A-Za-z]")
    let plain = ansi.stringByReplacingMatches(in: revoked, range: NSRange(revoked.startIndex..., in: revoked), withTemplate: "")
    #expect(plain.components(separatedBy: "\r\n").count == 24)
    #expect(plain.components(separatedBy: "\r\n").allSatisfy { $0.count == 79 })
    _ = ui.handle(.escape); _ = ui.handle(.escape)
    #expect(ui.render().contains("viewer"))
}

@Test func offlineChatSelectionScrollbackAndResizePreserveTranscript() {
    var ui = KilnTerminal(); ui.resize(width: 120, height: 30); _ = ui.handle(.text("7"))
    _ = ui.handle(.text("fixture")); _ = ui.handle(.enter)
    let answer = (0..<40).map { "line \($0) fixture output" }.joined(separator: "\n")
    ui.progress(.answer(answer)); ui.finish(text: answer, status: 0)
    #expect(ui.render().contains("line 39"))
    #expect(ui.handle(.selectText) == [.selectText(true)])
    let selected = ui.render()
    #expect(selected.contains("SELECT TEXT"))
    #expect(ui.handle(.text("should not type")).isEmpty)
    #expect(ui.handle(.enter).isEmpty)
    #expect(ui.render() == selected)
    #expect(ui.handle(.selectText) == [.selectText(false)])
    for _ in 0..<6 { _ = ui.handle(.pageUp) }
    #expect(ui.render().contains("line 0"))
    ui.resize(width: 80, height: 24)
    #expect(ui.render().contains("line 0"))
    for _ in 0..<10 { _ = ui.handle(.pageDown) }
    #expect(ui.render().contains("line 39"))
    ui.resize(width: 120, height: 30)
    #expect(ui.render().contains("line 39"))
}

private actor OfflineRetryAttempts {
    private var count = 0
    func next() -> Int { count += 1; return count }
}
@Test func offlineRetryCountdownKeepsSidebarFreshAndBlocksBusyApproval() async throws {
    let frames = TerminalFrames(), attempts = OfflineRetryAttempts()
    let proposal = AIProposalSnapshot(id: "offline-proposal", operation: "restart", module: "fixture/api", expires: Date().addingTimeInterval(300))
    frames.workspace(AIWorkspaceSnapshot(proposals: [proposal], tasks: [AITaskSnapshot(id: "offline-task", prompt: "Inspect fixture", status: "running")]))
    let answer: String = try await ProviderRetry.run(emit: { event in frames.receive(event) }, sleep: {
        #expect(frames.current().contains("Provider busy; retry"))
        #expect(frames.current().contains("APPROVAL / restart"))
        frames.workspace(AIWorkspaceSnapshot(proposals: [proposal], tasks: [AITaskSnapshot(id: "offline-task", prompt: "Inspect fixture", status: "completed")]))
        #expect(frames.current().contains("TASK / completed"))
        #expect(frames.handle(.mouse(button: 0, column: 4, row: 8, released: false)).isEmpty)
        #expect(!frames.current().contains("REVIEW OPERATION"))
    }) {
        if await attempts.next() == 1 {
            let response = HTTPURLResponse(url: URL(string: "https://terminal-fixture.invalid/retry")!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "2"])!
            var failure = ProviderFailure(response: response)
            _ = failure.append(Data("{\"error\":{\"code\":\"capacity_exceeded\"}}".utf8))
            throw failure
        }
        frames.receive(.answer("Recovered"))
        return "Recovered"
    }
    let final = frames.finish(answer)
    #expect(final.contains("[ready]") && final.contains("TASK / completed"))
    #expect(frames.snapshot().contains { $0.contains("retry 1/2 in 2s") })
    #expect(frames.snapshot().contains { $0.contains("retry 1/2 in 1s") })
    #expect(frames.handle(.mouse(button: 0, column: 4, row: 8, released: false)).isEmpty)
    #expect(frames.current().contains("app restart fixture/api"))
}
