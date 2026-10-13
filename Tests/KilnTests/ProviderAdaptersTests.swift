import Foundation
import Testing
@testable import KilnAI

@Test func deepSeekUsesExplicitWireAndDisablesThinking() throws {
    let call = AIToolCall(id: "call-one", type: "function", function: .init(name: "system_status", arguments: "{}"))
    var prior = AIMessage(role: "assistant", content: "Checking", tool_calls: [call])
    prior.providerItems = ["opaque-other-provider-fixture"]
    prior.reasoning_content = "other-provider-reasoning"
    let configuration = AIConfiguration(baseURL: "https://api.deepseek.com", model: "fixture", secret: "reference", provider: .deepseek)
    let request = try ChatCompletionsClient.request(configuration: configuration, key: "fixture-key", messages: [prior, AIMessage(role: "tool", content: "healthy", tool_call_id: call.id)], tools: [AITool("system_status", "Inspect runtime")])
    #expect(request.url?.absoluteString == "https://api.deepseek.com/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
    let requestData = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
    #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
    #expect(body["stream"] as? Bool == true)
    #expect(body["max_tokens"] as? Int == 4096)
    #expect(body["max_completion_tokens"] == nil)
    #expect(body["store"] == nil)
    let messages = try #require(body["messages"] as? [[String: Any]])
    #expect(messages[0]["providerItems"] == nil)
    #expect(messages[0]["reasoning_content"] == nil)
    #expect(messages[1]["tool_call_id"] as? String == "call-one")
    #expect(body["tool_choice"] as? String == "auto")
    #expect((body["tools"] as? [[String: Any]])?.count == 1)
}
@Test func deepSeekToolFreeRequestDoesNotAdvertiseTools() throws {
    let configuration = AIConfiguration(baseURL: "https://api.deepseek.com/v1", model: "fixture", secret: "reference", provider: .deepseek)
    let request = try ChatCompletionsClient.request(configuration: configuration, key: "fixture", messages: [AIMessage(role: "user", content: "hello")], tools: [])
    let requestData = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
    #expect(request.url?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
    #expect(body["tools"] == nil)
    #expect(body["tool_choice"] == nil)
    #expect(throws: (any Error).self) {
        try ChatCompletionsClient.request(configuration: AIConfiguration(baseURL: "https://api.openai.com/v1", model: "fixture", secret: "reference", provider: .openai), key: "fixture", messages: [], tools: [])
    }
}
@Test func nativeRemoteProviderConfigurationsRequireSafeURLsAndVaultReferences() throws {
    for provider in [AIProvider.openai, .anthropic, .grok, .deepseek] {
        let base = try #require(provider.defaultBaseURL)
        try AIConfiguration(baseURL: base, model: "fixture", secret: "reference", provider: provider).validate()
        for badURL in ["http://api.example.com", "https://user:password@api.example.com", "https://api.example.com?token=fixture", "https://api.example.com#fragment"] {
            #expect(throws: (any Error).self) {
                try AIConfiguration(baseURL: badURL, model: "fixture", secret: "reference", provider: provider).validate()
            }
        }
        #expect(throws: (any Error).self) {
            try AIConfiguration(baseURL: base, model: "fixture", secret: "", provider: provider).validate()
        }
    }
}
@Test func erebineWireExcludesOpaqueProviderItemsButRetainsToolHistory() throws {
    let call = AIToolCall(id: "one", type: "function", function: .init(name: "system_status", arguments: "{}"))
    var message = AIMessage(role: "assistant", content: nil, tool_calls: [call])
    message.providerItems = ["opaque-fixture"]
    message.reasoning_content = "provider-reasoning"
    let encoded = try JSONEncoder().encode(ErebineWireMessage(message))
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["providerItems"] == nil)
    #expect(object["reasoning_content"] as? String == "provider-reasoning")
    #expect((object["tool_calls"] as? [[String: Any]])?.first?["id"] as? String == "one")
    // Internal Codable must retain the opaque state needed by Responses replay.
    #expect(try JSONDecoder().decode(AIMessage.self, from: JSONEncoder().encode(message)).providerItems == ["opaque-fixture"])
}
