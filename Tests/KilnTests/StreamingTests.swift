import Foundation
import Testing
import KilnKit
import KilnTerminal
@testable import KilnAI

@Test func streamHandlesByteSplitsUTF8AndToolFragments() throws {
    var decoder = ErebineStreamDecoder()
    let input = """
    : keepalive

    data: {"choices":[{"delta":{"reasoning_content":"Checking…","reasoning":"Checking…"},"finish_reason":null}]}

    data: {"choices":[{"delta":{"content":"Hello é"},"finish_reason":null}]}

    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"one","function":{"name":"module_health","arguments":"{\\\"module\\\":"}}]},"finish_reason":null}]}

    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\\"demo/api\\\"}"}}]},"finish_reason":"tool_calls"}]}

    data: [DONE]


    """
    for byte in input.utf8 { try decoder.feed(Data([byte])) { _ in } }
    let message = try decoder.message()
    #expect(message.content == "Hello é")
    #expect(message.reasoning_content == "Checking…")
    #expect(message.tool_calls?.first?.function.arguments == "{\"module\":\"demo/api\"}")
}

@Test func interruptedOrTruncatedStreamCannotProduceTools() throws {
    var decoder = ErebineStreamDecoder()
    try decoder.feed(Data("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n".utf8)) { _ in }
    #expect(throws: (any Error).self) { try decoder.message() }
    #expect(throws: (any Error).self) {
        try decoder.feed(Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\n".utf8)) { _ in }
    }
}

@Test func selectionAndTaskShortcutsKeepInputLiteral() {
    var ui = KilnTerminal(); ui.resize(width: 120, height: 35)
    _ = ui.handle(.text("7"))
    #expect(ui.handle(.selectText) == [.selectText(true)])
    #expect(ui.handle(.text("should not be sent")).isEmpty)
    #expect(ui.handle(.selectText) == [.selectText(false)])
    _ = ui.handle(.text("/task check all services"))
    #expect(ui.handle(.enter) == [.command("ai task new \"check all services\"")])
    ui.progress(.reasoning("Provider text"))
    #expect(ui.render().contains("Provider thinking"))
    ui.progress(.answer("Partial answer"))
    #expect(ui.render().contains("Partial answer"))
    #expect(ui.render().contains("Provider thinking"))
    ui.finish(text: "Final answer", status: 0)
    #expect(!ui.render().contains("Partial answer"))
}

private actor Calls {
    var reads = 0
    var rounds = 0
    func complete(_ tools: [AITool]) throws -> AIMessage {
        rounds += 1
        if tools.isEmpty { return AIMessage(role: "assistant", content: "Collected status") }
        return try JSONDecoder().decode(AIMessage.self, from: Data("{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"call-\(rounds)\",\"type\":\"function\",\"function\":{\"name\":\"system_status\",\"arguments\":\"{}\"}}]}".utf8))
    }
    func read() -> String { reads += 1; return "running" }
}
@Test func repeatedToolsAreCachedAndBudgetEndsWithSummary() async throws {
    let calls = Calls()
    let assistant = KilnAssistant { _, _, _, tools in try await calls.complete(tools) }
    let result = try await assistant.ask("inspect", session: "test", configuration: AIConfiguration(baseURL: "https://example.com/v1", model: "test", secret: "test"), key: "test", modules: [], context: "", knowledge: nil) { _, _ in await calls.read() }
    #expect(result == "Collected status")
    #expect(await calls.reads == 1)
    #expect(await calls.rounds == 9)
}

@Test func tasksQueueCancelPersistAndDoNotReplayAfterRestart() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let tasks = AITasks(directory: directory)
    _ = try await tasks.limit(1)
    let first = try await tasks.submit("first") { _, _, _ in try await Task.sleep(for: .seconds(20)); return "finished" }
    let id = String(first.split(separator: "\n")[0].dropFirst("Task created: ".count))
    let second = try await tasks.submit("second") { _, _, emit in emit(.answer("live")); return "done" }
    let secondID = String(second.split(separator: "\n")[0].dropFirst("Task created: ".count))
    #expect(try await tasks.show(secondID).contains("[queued]"))
    _ = try await tasks.cancel(id)
    for _ in 0..<100 {
        if try await tasks.show(secondID).contains("[completed]") { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(try await tasks.show(secondID).contains("[completed]"))
    let restored = AITasks(directory: directory)
    #expect(try await restored.show(id).contains("[cancelled]"))
    #expect(try await restored.show(secondID).contains("done"))
    _ = try await restored.limit(48)
    do { _ = try await restored.limit(49); Issue.record("Exceeded concurrency cap") } catch {}
}

@Test func backgroundAssistantCannotProposeMutationsOrSpawnTasks() async throws {
    let calls = Calls()
    let assistant = KilnAssistant { _, _, _, tools in
        #expect(!tools.contains { ["request_operation", "create_task"].contains($0.function.name) })
        return try JSONDecoder().decode(AIMessage.self, from: Data("{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"forged\",\"type\":\"function\",\"function\":{\"name\":\"create_task\",\"arguments\":\"{\\\"request\\\":\\\"recursive work\\\"}\"}}]}".utf8))
    }
    let result = try await assistant.ask("inspect", session: "task:test", configuration: AIConfiguration(baseURL: "https://example.com/v1", model: "test", secret: "test"), key: "test", modules: [], context: "", knowledge: nil, allowProposals: false) { _, _ in await calls.read() }
    #expect(await calls.reads == 0)
    #expect(result.contains("Tool rejected"))
}

@Test func queuedWorkBecomesInterruptedOnReloadWithoutExecution() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let tasks = AITasks(directory: directory)
    let receipt = try await tasks.submit("work") { _, _, _ in try await Task.sleep(for: .seconds(30)); return "done" }
    let id = String(receipt.split(separator: "\n")[0].dropFirst("Task created: ".count))
    let recovered = AITasks(directory: directory)
    #expect(try await recovered.show(id).contains("[interrupted]"))
    _ = try await tasks.cancel(id)
}

private actor WorkerGate {
    var count = 0
    var peak = 0
    var released = false
    var waiting: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        count += 1; peak = max(peak, count)
        if !released { await withCheckedContinuation { waiting.append($0) } }
        count -= 1
    }
    func release() { released = true; for c in waiting { c.resume() }; waiting = [] }
}
@Test func schedulerAdmitsAtMost48Workers() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let tasks = AITasks(directory: directory); let gate = WorkerGate()
    _ = try await tasks.limit(48)
    for n in 0..<49 { _ = try await tasks.submit("test \(n)") { _, _, _ in await gate.enter(); return "done" } }
    for _ in 0..<200 { if await gate.count == 48 { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(await gate.count == 48)
    #expect(try await tasks.list().contains("queued"))
    await gate.release()
    for _ in 0..<200 { if !(try await tasks.list()).contains("running  test") { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(await gate.peak == 48)
}

@Test func unavailableFinalSummaryStillReturnsCollectedFacts() async throws {
    let calls = Calls()
    let assistant = KilnAssistant { _, _, _, tools in
        if tools.isEmpty { throw AIError.message("Summary endpoint unavailable") }
        return try await calls.complete(tools)
    }
    let result = try await assistant.ask("inspect", session: "test", configuration: AIConfiguration(baseURL: "https://example.com/v1", model: "test", secret: "test"), key: "test", modules: [], context: "", knowledge: nil) { _, _ in await calls.read() }
    #expect(result.contains("Verified results"))
    #expect(result.contains("running"))
    #expect(await calls.reads == 1)
}

@Test func chatPreservesLiveLinesAndAnimatesWaiting() {
    var ui = KilnTerminal(); ui.resize(width: 120, height: 35)
    _ = ui.handle(.text("7")); _ = ui.handle(.text("check")); _ = ui.handle(.enter)
    let waiting = ui.render(); ui.tick()
    #expect(ui.render() != waiting)
    ui.progress(.answer("**First**\nSecond"))
    let frame = ui.render()
    #expect(frame.contains("First")); #expect(frame.contains("Second"))
    #expect(!frame.contains("First?Second")); #expect(!frame.contains("**"))
    #expect(!frame.contains("Command completed"))
    #expect(!frame.contains("LOCAL NODE"))
    ui.finish(text: "**First**\nSecond", status: 0)
    #expect(ui.render().contains("[ready]"))
}

@Test func erebineLetsTheServedModelDetermineItsAvailableResponseBudget() throws {
    let config = AIConfiguration(baseURL:"https://example.com/v1",model:"fixture",secret:"reference")
    for streaming in [true,false] {
        let request = try ErebineClient.request(configuration:config,key:"fixture",messages:[AIMessage(role:"user",content:"Explain")],tools:[],streaming:streaming)
        let bytes = try #require(request.httpBody)
        let object = try JSONSerialization.jsonObject(with:bytes)
        let body = try #require(object as? [String:Any])
        #expect(body["max_completion_tokens"] == nil)
        #expect(body["max_tokens"] == nil)
        #expect(body["reasoning"] == nil)
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == streaming)
        #expect(body["parallel_tool_calls"] as? Bool == streaming)
        #expect(request.value(forHTTPHeaderField:"X-Erebine-Augment-Max-Output-Tokens-Clamp") == nil)
        #expect(body["reasoning_effort"] == nil) // preserve provider/model reasoning defaults
    }
}
@Test func largerReasoningStreamStillRequiresACompleteBoundedToolCall() throws {
    var decoder = ErebineStreamDecoder()
    func event(_ choice: [String:Any]) throws -> Data {
        Data("data: ".utf8) + (try JSONSerialization.data(withJSONObject:["choices":[choice]])) + Data("\n\n".utf8)
    }
    try decoder.feed(event(["delta":["reasoning_content":String(repeating:"reasoning ",count:8000)]])) { _ in }
    try decoder.feed(event(["delta":["tool_calls":[["index":0,"id":"complete","function":["name":"system_status","arguments":"{}"]]]],"finish_reason":"tool_calls"])) { _ in }
    try decoder.feed(Data("data: [DONE]\n\n".utf8)) { _ in }
    #expect(try decoder.message().tool_calls?.first?.function.name == "system_status")
    #expect(try decoder.message().reasoning_content?.utf8.count == 80000)
    var truncated = ErebineStreamDecoder()
    do {
        try truncated.feed(event(["delta":[:],"finish_reason":"length"])) { _ in }
        Issue.record("Truncated generation accepted")
    } catch { #expect(String(describing:error).contains("response token limit")) }
    #expect(throws:(any Error).self) { try truncated.message() }
    var bounded = ErebineStreamDecoder()
    #expect(throws:(any Error).self) {
        try bounded.feed(event(["delta":["reasoning_content":String(repeating:"x",count:ErebineClient.messageByteLimit+1)]])) { _ in }
    }
}
