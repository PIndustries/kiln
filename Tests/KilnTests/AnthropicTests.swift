import Foundation
import Testing
@testable import KilnAI

private func claudeEvent(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return "event: \(object["type"]!)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
}
private func claudeStart() throws -> String {
    try claudeEvent(["type": "message_start", "message": ["role": "assistant", "content": []]])
}
private func claudeEnd(_ reason: String) throws -> String {
    try claudeEvent(["type": "message_delta", "delta": ["stop_reason": reason]]) + claudeEvent(["type": "message_stop"])
}

@Test func claudeMapsSystemToolsAndConsecutiveResults() throws {
    let config = AIConfiguration(baseURL: "https://api.anthropic.com/v1", model: "claude-fixture", secret: "test", provider: .anthropic)
    let calls = [AIToolCall(id: "one", type: "function", function: .init(name: "status", arguments: "{}")),
                 AIToolCall(id: "two", type: "function", function: .init(name: "health", arguments: "{\"module\":\"api\"}"))]
    let messages = [AIMessage(role: "system", content: "Rules"), AIMessage(role: "user", content: "Check"),
                    AIMessage(role: "assistant", content: "Checking", tool_calls: calls),
                    AIMessage(role: "tool", content: "OK", tool_call_id: "one"),
                    AIMessage(role: "tool", content: "Healthy", tool_call_id: "two")]
    let request = try AnthropicClient.request(configuration: config, key: "fixture-key", messages: messages, tools: [AITool("status", "Inspect")])
    #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "fixture-key")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    let requestBody = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
    #expect(body["system"] as? String == "Rules")
    #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
    let history = try #require(body["messages"] as? [[String: Any]])
    #expect(history.count == 3)
    #expect((history[2]["content"] as? [[String: Any]])?.count == 2)
    #expect((body["tools"] as? [[String: Any]])?.first?["input_schema"] != nil)
    #expect(throws: AIError.self) {
        try AnthropicClient.request(configuration: config, key: "fixture-key", messages: [AIMessage(role: "tool", content: "orphan", tool_call_id: "missing")], tools: [])
    }
}

@Test func claudeStreamsFragmentedUTF8AndToolArguments() throws {
    var wire = try claudeStart()
    wire += try claudeEvent(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]])
    wire += try claudeEvent(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Hello 🌍"]])
    wire += try claudeEvent(["type": "content_block_stop", "index": 0])
    wire += try claudeEvent(["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "tool_1", "name": "health", "input": [:]]])
    for fragment in ["{\"module\":", "\"api\"}"] {
        wire += try claudeEvent(["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": fragment]])
    }
    wire += try claudeEvent(["type": "content_block_stop", "index": 1])
    wire += try claudeEnd("tool_use")
    var decoder = AnthropicStreamDecoder()
    for byte in wire.utf8 { try decoder.feed(Data([byte])) { _ in } }
    let result = try decoder.message()
    #expect(result.content == "Hello 🌍")
    #expect(result.tool_calls?.first?.function.arguments == "{\"module\":\"api\"}")
    #expect(result.tool_calls?.first?.id == "tool_1")
}

@Test func claudeRejectsIncompleteTruncatedAndErrorStreams() throws {
    var decoder = AnthropicStreamDecoder()
    try decoder.feed(Data(try claudeStart().utf8)) { _ in }
    #expect(throws: AIError.self) { try decoder.message() }
    #expect(throws: AIError.self) { try decoder.feed(Data(try claudeEnd("max_tokens").utf8)) { _ in } }
    var error = AnthropicStreamDecoder()
    #expect(throws: AIError.self) {
        try error.feed(Data(try claudeEvent(["type": "error", "error": ["message": "SECRET_VALUE"]]).utf8)) { _ in }
    }
    do {
        var privateError = AnthropicStreamDecoder()
        try privateError.feed(Data(try claudeEvent(["type": "error", "error": ["message": "SECRET_VALUE"]]).utf8)) { _ in }
        Issue.record("Expected stream rejection")
    } catch { #expect(!String(describing: error).contains("SECRET_VALUE")) }
}

@Test func claudeRejectsInvalidToolJSONAndUnexpectedThinking() throws {
    var decoder = AnthropicStreamDecoder()
    var wire = try claudeStart()
    wire += try claudeEvent(["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": "a", "name": "status", "input": [:]]])
    wire += try claudeEvent(["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": "{broken"]])
    wire += try claudeEvent(["type": "content_block_stop", "index": 0])
    #expect(throws: AIError.self) { try decoder.feed(Data(wire.utf8)) { _ in } }
    var thinking = AnthropicStreamDecoder()
    #expect(throws: AIError.self) {
        try thinking.feed(Data((try claudeStart() + claudeEvent(["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]])).utf8)) { _ in }
    }
}

@Test func claudeAcceptsOnlyCompletedTextResponse() throws {
    var decoder = AnthropicStreamDecoder()
    var wire = try claudeStart()
    wire += try claudeEvent(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": "Ready"]])
    wire += try claudeEvent(["type": "content_block_stop", "index": 0])
    wire += try claudeEnd("end_turn")
    try decoder.feed(Data(wire.utf8)) { _ in }
    #expect(try decoder.message().content == "Ready")
    #expect(try decoder.message().tool_calls == nil)
}
