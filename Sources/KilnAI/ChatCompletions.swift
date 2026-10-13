import Foundation
import KilnKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Explicit DeepSeek wire contract; shared JSON does not imply identical options.
struct ChatCompletionsClient {
    let metrics: AIProviderMetrics
    static func request(configuration: AIConfiguration, key: String, messages: [AIMessage], tools: [AITool]) throws -> URLRequest {
        try configuration.validate()
        guard configuration.provider == .deepseek else { throw AIError.message("Wrong chat-completions provider") }
        let wireMessages: [[String: Any]] = messages.map { message in
            var value: [String: Any] = ["role": message.role]
            if let text = message.content { value["content"] = text }
            if let id = message.tool_call_id { value["tool_call_id"] = id }
            if let calls = message.tool_calls {
                value["tool_calls"] = calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.function.name, "arguments": $0.function.arguments]] as [String: Any] }
            }
            return value
        }
        var body: [String: Any] = ["model": configuration.model, "messages": wireMessages,
                                 "stream": true, "max_tokens": 4096, "thinking": ["type": "disabled"]]
        if !tools.isEmpty {
            body["tools"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tools))
            body["tool_choice"] = "auto"
        }
        var request = URLRequest(url: URL(string: configuration.baseURL)!.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"; request.timeoutInterval = 90
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    func stream(configuration: AIConfiguration, key: String, messages: [AIMessage], tools: [AITool],
                emit: @escaping @Sendable (AIProgress) -> Void) async throws -> AIMessage {
        let request = try Self.request(configuration: configuration, key: key, messages: messages, tools: tools)
        return try await ProviderRetry.run(metrics: metrics, emit: emit) {
            try await ErebineClient().streamAttempt(request: request, emit: emit)
        }
    }
}
