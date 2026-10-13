import Foundation
import Testing
import KilnKit
@testable import KilnAI

private func responseEvent(_ object: [String: Any]) throws -> Data {
    var data = Data("data: ".utf8)
    data.append(try JSONSerialization.data(withJSONObject: object))
    data.append(Data("\n\n".utf8)); return data
}
private func completedResponse(_ output: [[String: Any]]) throws -> Data {
    try responseEvent(["type": "response.completed", "response": ["status": "completed", "output": output]])
}
private func responseText(_ text: String) -> [String: Any] {
    ["type": "message", "id": "msg1", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": text, "annotations": []]]]
}
@Test func responsesHandlesByteSplitsAndPreservesEncryptedToolRound() throws {
    var decoder = OpenAIResponsesDecoder()
    let reasoning: [String: Any] = ["type": "reasoning", "id": "rs1", "summary": [], "encrypted_content": "opaque-test-fixture"]
    let call: [String: Any] = ["type": "function_call", "id": "fc1", "call_id": "call1", "name": "system_status", "arguments": "{}", "status": "completed"]
    let delta = try responseEvent(["type": "response.output_text.delta", "delta": "Hello é"])
    let finish = try completedResponse([reasoning, responseText("Hello é"), call])
    for byte in delta + finish { try decoder.feed(Data([byte])) { _ in } }
    let answer = try decoder.message()
    #expect(answer.content == "Hello é")
    #expect(answer.tool_calls?.first?.id == "call1")
    #expect(answer.providerItems?.count == 3)
    #expect(answer.reasoning_content == nil)
    let config = AIConfiguration(baseURL: "https://api.openai.com/v1", model: "fixture", secret: "reference", provider: .openai)
    let request = try OpenAIResponsesClient.makeRequest(configuration: config, key: "fixture", messages: [answer, AIMessage(role: "tool", content: "healthy", tool_call_id: "call1")], tools: [AITool("system_status", "Status")])
    let requestData = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
    let input = try #require(body["input"] as? [[String: Any]])
    #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
    #expect(body["store"] as? Bool == false)
    #expect(input.count == 4)
    #expect(input[0]["encrypted_content"] as? String == "opaque-test-fixture")
    #expect(input[3]["type"] as? String == "function_call_output")
    #expect(input[3]["call_id"] as? String == "call1")
    let tools = try #require(body["tools"] as? [[String: Any]])
    #expect(tools.first?["name"] as? String == "system_status")
    #expect(tools.first?["strict"] as? Bool == true)
}
@Test func responsesRejectsIncompleteFailedAndInterruptedTools() throws {
    for type in ["response.incomplete", "response.failed", "error"] {
        var decoder = OpenAIResponsesDecoder()
        #expect(throws: (any Error).self) { try decoder.feed(responseEvent(["type": type, "message": "SECRET MUST NOT BE REFLECTED"])) { _ in } }
        #expect(throws: (any Error).self) { try decoder.message() }
    }
    var decoder = OpenAIResponsesDecoder()
    try decoder.feed(responseEvent(["type": "response.function_call_arguments.delta", "delta": "{}", "item_id": "fc1"])) { _ in }
    #expect(throws: (any Error).self) { try decoder.message() }
    #expect(throws: (any Error).self) {
        try decoder.feed(completedResponse([["type": "function_call", "call_id": "one", "name": "restart", "arguments": "{", "status": "completed"]])) { _ in }
    }
}
@Test func responsesReturnsRefusalAndRejectsDuplicateCalls() throws {
    var decoder = OpenAIResponsesDecoder()
    try decoder.feed(completedResponse([["type": "message", "role": "assistant", "status": "completed", "content": [["type": "refusal", "refusal": "Cannot perform that action"]]]])) { _ in }
    #expect(try decoder.message().content == "Cannot perform that action")
    let call: [String: Any] = ["type": "function_call", "call_id": "duplicate", "name": "system_status", "arguments": "{}"]
    var invalid = OpenAIResponsesDecoder()
    #expect(throws: (any Error).self) { try invalid.feed(completedResponse([call, call])) { _ in } }
}
@Test func responsesGrokUsesStatelessResponsesAndEncryptedReplay() throws {
    let config = AIConfiguration(baseURL: "https://api.x.ai/v1", model: "fixture", secret: "reference", provider: .grok)
    let request = try OpenAIResponsesClient.makeRequest(configuration: config, key: "fixture", messages: [AIMessage(role: "user", content: "hello")], tools: [])
    let requestData = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
    #expect(request.url?.absoluteString == "https://api.x.ai/v1/responses")
    #expect(body["include"] as? [String] == ["reasoning.encrypted_content"])
    #expect(body["store"] as? Bool == false)
}
@Test func responsesBoundsStreamAndRejectsUnsupportedOutput() throws {
    var decoder = OpenAIResponsesDecoder()
    #expect(throws: (any Error).self) { try decoder.feed(Data(repeating: 65, count: 262145)) { _ in } }
    var unsupported = OpenAIResponsesDecoder()
    #expect(throws: (any Error).self) { try unsupported.feed(completedResponse([["type": "web_search_call", "status": "completed"]])) { _ in } }
}
@Test func responsesErrorsNeverReflectProviderPayloadAndRequireCompletedStatus() throws {
    var decoder = OpenAIResponsesDecoder()
    do {
        try decoder.feed(responseEvent(["type": "error", "message": "fixture-sensitive-value"])) { _ in }
        Issue.record("Expected failed provider event")
    } catch { #expect(!String(describing: error).contains("fixture-sensitive-value")) }
    var incomplete = OpenAIResponsesDecoder()
    #expect(throws: (any Error).self) {
        try incomplete.feed(responseEvent(["type": "response.completed", "response": ["status": "incomplete", "output": [responseText("partial")]]])) { _ in }
    }
}
