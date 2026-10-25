import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension ErebineClient {
    // Do not send a generation ceiling. Erebine resolves the actual served
    // model and uses its remaining context window when both token fields are absent.
    static let messageByteLimit = 262144
    static func request(configuration: AIConfiguration, key: String, messages: [AIMessage], tools: [AITool], streaming: Bool) throws -> URLRequest {
        try configuration.validate()
        struct Body: Encodable {
            let model: String
            let messages: [ErebineWireMessage]
            let tools: [AITool]
            let stream: Bool
            let store = false
            let parallel_tool_calls: Bool
            let tool_choice: String?
        }
        var request = URLRequest(url: URL(string: configuration.baseURL)!.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"; request.timeoutInterval = 90
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("KilnAI/1", forHTTPHeaderField: "User-Agent")
        if streaming { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        request.httpBody = try JSONEncoder().encode(Body(model:configuration.model,messages:messages.map(ErebineWireMessage.init),tools:tools,stream:streaming,parallel_tool_calls:streaming,tool_choice:streaming ? (tools.isEmpty ? "none" : "auto") : nil))
        return request
    }
}
