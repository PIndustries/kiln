import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension ErebineClient {
    // Reasoning and tool arguments share this budget. A 4K ceiling regularly
    // exhausted itself planning edits before a complete tool call was produced.
    static let completionTokenLimit = 16384
    static let messageByteLimit = 262144
    static func request(configuration: AIConfiguration, key: String, messages: [AIMessage], tools: [AITool], streaming: Bool) throws -> URLRequest {
        try configuration.validate()
        struct Body: Encodable {
            let model: String
            let messages: [ErebineWireMessage]
            let tools: [AITool]
            let stream: Bool
            let store = false
            let max_completion_tokens = ErebineClient.completionTokenLimit
            let parallel_tool_calls: Bool
            let tool_choice: String?
        }
        var request = URLRequest(url: URL(string: configuration.baseURL)!.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"; request.timeoutInterval = 90
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("KilnAI/1", forHTTPHeaderField: "User-Agent")
        // Documented opt-in: fit the output budget to the endpoint's remaining
        // context window instead of rejecting a large default with HTTP 400.
        request.setValue("on", forHTTPHeaderField: "X-Erebine-Augment-Max-Output-Tokens-Clamp")
        if streaming { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        request.httpBody = try JSONEncoder().encode(Body(model:configuration.model,messages:messages.map(ErebineWireMessage.init),tools:tools,stream:streaming,parallel_tool_calls:streaming,tool_choice:streaming ? (tools.isEmpty ? "none" : "auto") : nil))
        return request
    }
}
