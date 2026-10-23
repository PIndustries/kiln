import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import KilnKit
@testable import KilnAI

private func usageEvent(_ value: [String: Any]) throws -> Data {
    Data("data: ".utf8) + (try JSONSerialization.data(withJSONObject: value)) + Data("\n\n".utf8)
}

@Test func reportedUsageRejectsInvalidCountsAndKeepsMissingDistinctFromZero() throws {
    for value in [true, false, -1, 1.25, "12", NSNull(), Double.infinity, 9_007_199_254_740_992.0] {
        #expect(AIProviderUsage.count(value) == nil)
    }
    #expect(AIProviderUsage.count(0) == 0)
    #expect(AIProviderUsage.count(12) == 12)
    let usage = AIProviderUsage.responses(["input_tokens": 0, "output_tokens": 3, "total_tokens": NSNull()])
    #expect(usage.inputTokens == 0 && usage.outputTokens == 3 && usage.totalTokens == nil)
    #expect(usage.summary.contains("total=unavailable"))
}

@Test func responsesAndChatCompletionUsageSurviveFragmentationWithoutWireReplay() throws {
    var responses = OpenAIResponsesDecoder()
    let wire = try usageEvent(["type": "response.completed", "response": ["status": "completed", "output": [],
        "usage": ["input_tokens": 20, "output_tokens": 8, "total_tokens": 28,
                  "input_tokens_details": ["cached_tokens": 10], "output_tokens_details": ["reasoning_tokens": 4]]]])
    for byte in wire { try responses.feed(Data([byte])) { _ in } }
    let result = try responses.message()
    #expect(result.usage == AIProviderUsage(inputTokens: 20, outputTokens: 8, totalTokens: 28, cachedInputTokens: 10, reasoningTokens: 4))
    var chat = ErebineStreamDecoder()
    let chunks = try usageEvent(["choices": [["finish_reason": "stop", "delta": ["content": "OK"]]]])
        + usageEvent(["choices": [], "usage": ["prompt_tokens": 12, "completion_tokens": 2, "total_tokens": 14, "prompt_cache_hit_tokens": 6]])
        + Data("data: [DONE]\n\n".utf8)
    for byte in chunks { try chat.feed(Data([byte])) { _ in } }
    let message = try chat.message()
    #expect(message.content == "OK" && message.usage?.cachedInputTokens == 6)
    #expect(message.usage?.totalTokens == 14)
    // Internal Codable retains diagnostics; no adapter sends them as model history.
    #expect(try JSONDecoder().decode(AIMessage.self, from: JSONEncoder().encode(message)).usage == message.usage)
    let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ErebineWireMessage(message))) as? [String: Any])
    #expect(encoded["usage"] == nil)
    for provider in [AIProvider.openai, .grok, .deepseek, .anthropic, .ollama] {
        let config = AIConfiguration(baseURL: provider.defaultBaseURL!, model: "fixture", secret: provider == .ollama ? "" : "reference", provider: provider)
        let request: URLRequest
        switch provider {
        case .openai, .grok: request = try OpenAIResponsesClient.makeRequest(configuration: config, key: "fixture", messages: [message], tools: [])
        case .deepseek: request = try ChatCompletionsClient.request(configuration: config, key: "fixture", messages: [message], tools: [])
        case .anthropic: request = try AnthropicClient.request(configuration: config, key: "fixture", messages: [message], tools: [])
        default: request = try OllamaClient().request(configuration: config, messages: [message], tools: [])
        }
        #expect(!String(decoding: request.httpBody!, as: UTF8.self).contains("Tokens"))
        #expect(!String(decoding: request.httpBody!, as: UTF8.self).contains("usage"))
    }
}

@Test func claudeCumulativeUsageReplacesRatherThanDoubleCounts() throws {
    func event(_ type: String, _ fields: [String: Any] = [:]) throws -> Data {
        var value = fields; value["type"] = type; return try usageEvent(value)
    }
    var decoder = AnthropicStreamDecoder()
    let wire = try event("message_start", ["message": ["role": "assistant", "content": [], "usage": ["input_tokens": 30, "output_tokens": 1, "cache_read_input_tokens": 10, "cache_creation_input_tokens": 5]]])
        + event("message_delta", ["delta": [:], "usage": ["output_tokens": 4]])
        + event("message_delta", ["delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 9]])
        + event("message_stop")
    try decoder.feed(wire) { _ in }
    #expect(try decoder.message().usage == AIProviderUsage(inputTokens: 30, outputTokens: 9, cachedInputTokens: 10, cacheWriteInputTokens: 5))
    var interrupted = AnthropicStreamDecoder()
    try interrupted.feed(event("message_start", ["message": ["role": "assistant", "content": [], "usage": ["input_tokens": 30]]])) { _ in }
    #expect(throws: AIError.self) { try interrupted.message() }
}

@Test func ollamaUsesOnlyFinalReportedCountsWithoutInventingTotal() throws {
    var decoder = OllamaStreamDecoder()
    try decoder.feed(Data("{\"done\":false,\"message\":{\"role\":\"assistant\",\"content\":\"OK\"},\"eval_count\":999}\n{\"done\":true,\"done_reason\":\"stop\",\"prompt_eval_count\":15,\"eval_count\":2}\n".utf8)) { _ in }
    #expect(try decoder.finish { _ in }.usage == AIProviderUsage(inputTokens: 15, outputTokens: 2))
}

@Test func usageMetricsKeepFixedProviderCardinalityAndUnknownCoverage() async throws {
    let metrics = AIProviderMetrics()
    await metrics.recordUsage(provider: .openai, usage: .init(inputTokens: 10, outputTokens: 3, totalTokens: 13))
    await metrics.recordUsage(provider: .openai, usage: nil)
    await metrics.recordUsage(provider: .openai, usage: .init(inputTokens: 0, outputTokens: 0, totalTokens: 0))
    await metrics.recordUsage(provider: .anthropic, usage: .init(inputTokens: 20, outputTokens: 4))
    let snapshot = await metrics.snapshot()
    let openai = try #require(snapshot.usageByProvider["openai"])
    #expect(openai.completedResponses == 3 && openai.responsesWithUsage == 2)
    #expect(openai.reported.totalTokens == 13)
    #expect(snapshot.usageByProvider["anthropic"]?.reported.totalTokens == nil)
    #expect(snapshot.summary.contains("Cost and remaining account limits: unavailable"))
    #expect(snapshot.usageByProvider.count == 2)
}
