import Foundation
import Testing
import KilnKit
@testable import KilnAI

private func contextCall(_ id: String, operation: Bool = false) throws -> AIToolCall {
    let value: [String: Any] = ["id": id, "type": "function", "function": ["name": operation ? "request_operation" : "system_status", "arguments": operation ? "{\"module\":\"demo/worker\",\"operation\":\"stop\"}" : "{}"]]
    return try JSONDecoder().decode(AIToolCall.self, from: JSONSerialization.data(withJSONObject: value))
}

@Test func boundedHistoryRetainsRecentWholeOperatorTurnsAndPairedTools() throws {
    var history = AIConversationHistory()
    for index in 0..<10 {
        let turn = [AIMessage(role: "user", content: "operator \(index)"),
                    AIMessage(role: "assistant", content: nil, tool_calls: [try contextCall("call-\(index)")]),
                    AIMessage(role: "tool", content: "verified", tool_call_id: "call-\(index)"),
                    AIMessage(role: "user", content: "Internal tool-budget instruction"),
                    AIMessage(role: "assistant", content: "answer \(index)")]
        history = history.recording(history.messages + turn)
    }
    let trimmed = history.trim(); #expect(trimmed)
    #expect(history.messages.count == 40)
    #expect(history.messages.first?.content == "operator 2")
    #expect(history.messages.last?.content == "answer 9")
    #expect(history.turnStarts == Array(stride(from: 0, to: 40, by: 5)))
    let calls = Set(history.messages.flatMap { $0.tool_calls ?? [] }.map(\.id))
    #expect(history.messages.filter { $0.role == "tool" }.allSatisfy { calls.contains($0.tool_call_id ?? "") })
    let trimmedAgain = history.trim(); #expect(!trimmedAgain)
}

@Test func boundedHistoryEnforcesEncodedByteLimitAndDropsAnIndivisibleOversizedTurn() throws {
    var history = AIConversationHistory()
    for index in 0..<4 {
        history = history.recording(history.messages + [AIMessage(role: "user", content: "operator \(index)"), AIMessage(role: "assistant", content: String(repeating: "🌱", count: 6000))])
    }
    let trimmed = history.trim(); #expect(trimmed)
    #expect(try JSONEncoder().encode(history.messages).count <= 65536)
    #expect(history.messages.first?.content == "operator 2")
    var oversized = AIConversationHistory().recording([AIMessage(role: "user", content: "request"), AIMessage(role: "assistant", content: String(repeating: "a", count: 70000))])
    let dropped = oversized.trim(); #expect(dropped)
    #expect(oversized.messages.isEmpty && oversized.turnStarts.isEmpty)
    oversized = oversized.recording([AIMessage(role: "user", content: "fresh"), AIMessage(role: "assistant", content: "answer")])
    let freshTrimmed = oversized.trim(); #expect(!freshTrimmed)
}

private actor ContextProbe {
    var requests: [[AIMessage]] = []
    func next(_ messages: [AIMessage]) throws -> AIMessage {
        requests.append(messages)
        if messages.last?.role == "user", messages.last?.content == "propose" {
            return AIMessage(role: "assistant", content: nil, tool_calls: [try contextCall(UUID().uuidString, operation: true)])
        }
        return AIMessage(role: "assistant", content: "Completed")
    }
}
private let contextConfig = AIConfiguration(baseURL: "http://127.0.0.1:11434", model: "fixture", secret: "", provider: .ollama)
private let contextModule = ModuleSnapshot(application: "demo", name: "worker", version: "1", state: "running", pid: 123)
private func contextAsk(_ ai: KilnAssistant, _ prompt: String, session: String = "chat") async throws -> String {
    try await ai.ask(prompt, session: session, configuration: contextConfig, key: "", modules: [contextModule], context: "fixture", knowledge: nil) { _, _ in "running" }
}

@Test func assistantContextTrimmingKeepsRecentRequestsAndReportsTheBoundary() async throws {
    let probe = ContextProbe()
    let ai = KilnAssistant { _, _, messages, _ in try await probe.next(messages) }
    var result = ""
    for index in 0..<22 { result = try await contextAsk(ai, "operator \(index)") }
    #expect(result.contains("Context trimmed:"))
    let last = try #require(await probe.requests.last)
    #expect(!last.contains { $0.content == "operator 0" })
    #expect(last.contains { $0.content == "operator 1" })
    #expect(last.contains { $0.content == "operator 20" })
    #expect(last.last?.content == "operator 21")
    #expect(last.first?.content?.contains("Never reconstruct missing details") == true)
    #expect(last.count == 42) // 40 retained messages, system prompt, current request.
}

@Test func trimmingRevokesOnlyThatSessionsPendingInteractiveApprovals() async throws {
    let probe = ContextProbe()
    let ai = KilnAssistant { _, _, messages, _ in try await probe.next(messages) }
    _ = try await contextAsk(ai, "propose")
    _ = try await contextAsk(ai, "propose", session: "other")
    let proposal = try #require(await ai.pendingProposals(session: "chat").first)
    for index in 0..<19 { _ = try await contextAsk(ai, "follow up \(index)") }
    #expect(await ai.pendingProposals(session: "chat").count == 1)
    let result = try await contextAsk(ai, "trim now")
    #expect(result.contains("Previous interactive proposal IDs for this session were invalidated"))
    #expect(await ai.pendingProposals(session: "chat").isEmpty)
    #expect(await ai.pendingProposals(session: "other").count == 1)
    do { _ = try await ai.takeApproval(proposal.id, session: "chat"); Issue.record("Trimmed-context approval remained actionable") }
    catch {}
}
