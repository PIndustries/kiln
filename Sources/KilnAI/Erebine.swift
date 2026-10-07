import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AIError: Error, CustomStringConvertible, Sendable {
    case message(String)
    public var description: String { switch self { case .message(let text): return text } }
}
public struct AIConfiguration: Codable, Sendable {
    public let baseURL: String
    public let model: String
    public let secret: String
    public init(baseURL: String, model: String, secret: String) { self.baseURL = baseURL; self.model = model; self.secret = secret }
    public func validate() throws {
        guard let url = URL(string: baseURL), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !model.isEmpty, model.count < 256, !secret.isEmpty, secret.count <= 80 else {
            throw AIError.message("AI configuration requires an HTTPS base URL, model ID and Vault secret reference")
        }
    }
}
public struct AIToolCall: Codable, Sendable {
    public struct Function: Codable, Sendable { public let name: String; public let arguments: String }
    public let id: String
    public let type: String
    public let function: Function
}
public struct AIMessage: Codable, Sendable {
    public var role: String
    public var content: String?
    public var tool_calls: [AIToolCall]?
    public var tool_call_id: String?
    public var reasoning_content: String?
    public init(role: String, content: String?, tool_calls: [AIToolCall]? = nil, tool_call_id: String? = nil) {
        self.role = role; self.content = content; self.tool_calls = tool_calls; self.tool_call_id = tool_call_id
    }
}
public struct AITool: Encodable, Sendable {
    public struct Property: Codable, Sendable {
        public let type: String
        public let description: String
        public let `enum`: [String]?
        public init(_ description: String, values: [String]? = nil) { type = "string"; self.description = description; self.enum = values }
    }
    public struct Parameters: Encodable, Sendable {
        public let type = "object"
        public let properties: [String: Property]
        public let required: [String]
        public let additionalProperties = false
    }
    public struct Function: Encodable, Sendable {
        public let name: String
        public let description: String
        public let parameters: Parameters
    }
    public let type = "function"
    public let function: Function
    public init(_ name: String, _ description: String, properties: [String: Property] = [:]) {
        function = Function(name: name, description: description, parameters: Parameters(properties: properties, required: properties.keys.sorted()))
    }
}
private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Native Foundation HTTP; no OpenCode process, external SDK or shell transport.
public struct ErebineClient: Sendable {
    public init() {}
    public func complete(configuration: AIConfiguration, key: String, messages: [AIMessage], tools: [AITool]) async throws -> AIMessage {
        try configuration.validate()
        struct Request: Encodable {
            let model: String; let messages: [AIMessage]; let tools: [AITool]
            let stream = false; let store = false; let max_completion_tokens = 4096
            let parallel_tool_calls = false
        }
        struct Response: Decodable { struct Choice: Decodable { let message: AIMessage }; let choices: [Choice] }
        var request = URLRequest(url: URL(string: configuration.baseURL)!.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"; request.timeoutInterval = 90
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("KilnAI/1", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(Request(model: configuration.model, messages: messages, tools: tools))
        let options = URLSessionConfiguration.ephemeral
        options.httpCookieStorage = nil; options.urlCache = nil; options.timeoutIntervalForResource = 120
        let session = URLSession(configuration: options, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data; let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw AIError.message("Erebine request failed or timed out; no operation was automatically retried") }
        guard let response = response as? HTTPURLResponse else { throw AIError.message("Invalid Erebine response") }
        guard response.statusCode == 200 else { throw AIError.message("Erebine returned HTTP \(response.statusCode); check endpoint, model, quota and credential") }
        guard data.count <= 4_194_304, let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let message = decoded.choices.first?.message, message.role == "assistant" else { throw AIError.message("Invalid or oversized Erebine response") }
        guard (try? JSONEncoder().encode(message).count) ?? Int.max <= 65536 else { throw AIError.message("Erebine message exceeded the conversation limit") }
        return message
    }
}
