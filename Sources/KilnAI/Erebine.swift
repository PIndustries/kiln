import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AIError: Error, CustomStringConvertible, Sendable {
    case message(String)
    public var description: String { switch self { case .message(let text): return text } }
}
public enum AIProvider: String, Codable, Sendable, CaseIterable {
    case erebine, ollama, openai, anthropic, grok, deepseek, chatgpt
    public var requiresCredential: Bool { self != .ollama && self != .chatgpt }
    public var defaultBaseURL: String? {
        switch self {
        case .erebine: return nil
        case .ollama: return "http://127.0.0.1:11434"
        case .openai, .chatgpt: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .grok: return "https://api.x.ai/v1"
        case .deepseek: return "https://api.deepseek.com"
        }
    }
}
public struct AIConfiguration: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let baseURL: String
    public let model: String
    public let secret: String
    public let provider: AIProvider
    public let profile: String
    public let contextID: String
    public var credentialScope: String { profile == "default" ? "kiln/ai" : "kiln/ai-" + profile }
    public init(baseURL: String, model: String, secret: String, provider: AIProvider = .erebine,
                profile: String = "default", contextID: String = "legacy") {
        self.schemaVersion = 1
        self.baseURL = baseURL; self.model = model; self.secret = secret
        self.provider = provider; self.profile = profile; self.contextID = contextID
    }
    enum CodingKeys: String, CodingKey { case schemaVersion, baseURL, model, secret, provider, profile, contextID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard schemaVersion == 1 else { throw AIError.message("Unsupported AI profile schema version") }
        baseURL = try c.decode(String.self, forKey: .baseURL); model = try c.decode(String.self, forKey: .model)
        secret = try c.decodeIfPresent(String.self, forKey: .secret) ?? ""
        provider = try c.decodeIfPresent(AIProvider.self, forKey: .provider) ?? .erebine
        profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? "default"
        contextID = try c.decodeIfPresent(String.self, forKey: .contextID) ?? "legacy"
    }
    public func freshContext() -> AIConfiguration {
        AIConfiguration(baseURL: baseURL, model: model, secret: secret, provider: provider, profile: profile, contextID: UUID().uuidString)
    }
    public func validate() throws {
        guard let url = URL(string: baseURL), let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !model.isEmpty, model.utf8.count < 256, secret.count <= 80,
              !profile.isEmpty, profile.count <= 32,
              profile.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }),
              contextID.count <= 80 else { throw AIError.message("Invalid AI provider configuration") }
        switch provider {
        case .erebine, .openai, .anthropic, .grok, .deepseek:
            guard url.scheme == "https", !secret.isEmpty else { throw AIError.message("Remote AI providers require HTTPS and a Vault secret reference") }
        case .chatgpt:
            guard baseURL == "https://api.openai.com/v1", UUID(uuidString: secret) != nil else {
                throw AIError.message("ChatGPT profiles require the official endpoint and a signed-in account ID")
            }
        case .ollama:
            guard url.scheme == "http", ["127.0.0.1", "[::1]", "::1"].contains(host),
                  url.path.isEmpty || url.path == "/", secret.isEmpty else {
                throw AIError.message("Local Ollama requires a literal loopback HTTP origin and no credential; remote/cloud endpoints are not enabled")
            }
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
    /// Opaque provider-native history, consumed only by its matching adapter.
    public var providerItems: [String]?
    public init(role: String, content: String?, tool_calls: [AIToolCall]? = nil, tool_call_id: String? = nil) {
        self.role = role; self.content = content; self.tool_calls = tool_calls; self.tool_call_id = tool_call_id
    }
}
/// Chat-completions fields only: provider-native opaque history is never sent
/// to Erebine (or accidentally accepted as an extension to its wire schema).
struct ErebineWireMessage: Encodable {
    let role: String
    let content: String?
    let tool_calls: [AIToolCall]?
    let tool_call_id: String?
    let reasoning_content: String?
    init(_ message: AIMessage) {
        role = message.role; content = message.content
        tool_calls = message.tool_calls; tool_call_id = message.tool_call_id
        reasoning_content = message.reasoning_content
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
/// URLSession delivers delegate callbacks serially on its delegate queue. Only
/// those callbacks mutate the accumulator; cancellation only cancels the task.
private final class BoundedCompletionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maximumBytes = 4_194_304
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var bytes = Data()
    private var finished = false
    private var rejection: ProviderFailure?
    init(_ continuation: AsyncThrowingStream<Data, Error>.Continuation) { self.continuation = continuation }
    private func fail(_ message: String) {
        guard !finished else { return }
        finished = true; bytes.removeAll(keepingCapacity: false)
        continuation.finish(throwing: AIError.message(message))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else { fail("Invalid Erebine response"); completionHandler(.cancel); return }
        guard response.statusCode == 200 else {
            rejection = ProviderFailure(response: response)
            if response.expectedContentLength > Int64(ProviderFailure.maximumBytes) {
                fail(rejection!.explanation()); completionHandler(.cancel)
            } else { completionHandler(.allow) }
            return
        }
        guard response.expectedContentLength <= Int64(Self.maximumBytes) else {
            fail("Erebine response exceeded its 4 MiB size limit"); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        if rejection != nil {
            if !rejection!.append(data) { fail(rejection!.explanation()); dataTask.cancel() }
            return
        }
        // Content-Length can be absent, compressed, or wrong. Enforce the limit
        // on actual delivered bytes BEFORE appending, including chunked bodies.
        guard data.count <= Self.maximumBytes - bytes.count else {
            fail("Erebine response exceeded its 4 MiB size limit"); dataTask.cancel(); return
        }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        if let rejection { fail(rejection.explanation()); return }
        if error != nil { fail("Erebine request failed or timed out; no operation was automatically retried"); return }
        finished = true
        continuation.yield(bytes); continuation.finish()
        bytes.removeAll(keepingCapacity: false)
    }
}

enum BoundedCompletionHTTP {
    static func data(for request: URLRequest, configuration: URLSessionConfiguration) async throws -> Data {
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let delegate = BoundedCompletionDelegate(pair.continuation)
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        let task = session.dataTask(with: request)
        defer { task.cancel(); session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation(); task.resume()
                for try await data in pair.stream { try Task.checkCancellation(); return data }
                throw AIError.message("Erebine returned no response")
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: { task.cancel() }
    }
}

/// Native Foundation HTTP; no OpenCode process, external SDK or shell transport.
public struct ErebineClient: Sendable {
    public let metrics: AIProviderMetrics
    public init(metrics: AIProviderMetrics = AIProviderMetrics()) { self.metrics = metrics }
    public func complete(configuration: AIConfiguration, key: String, messages: [AIMessage], tools: [AITool]) async throws -> AIMessage {
        try configuration.validate()
        struct Request: Encodable {
            let model: String; let messages: [ErebineWireMessage]; let tools: [AITool]
            let stream = false; let store = false; let max_completion_tokens = 4096
            let parallel_tool_calls = false
        }
        struct Response: Decodable { struct Choice: Decodable { let message: AIMessage }; let choices: [Choice] }
        var request = URLRequest(url: URL(string: configuration.baseURL)!.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"; request.timeoutInterval = 90
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("KilnAI/1", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(Request(model: configuration.model, messages: messages.map(ErebineWireMessage.init), tools: tools))
        let options = URLSessionConfiguration.ephemeral
        options.httpCookieStorage = nil; options.urlCache = nil; options.timeoutIntervalForResource = 120
        let data = try await BoundedCompletionHTTP.data(for: request, configuration: options)
        guard data.count <= 4_194_304, let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let message = decoded.choices.first?.message, message.role == "assistant" else { throw AIError.message("Invalid or oversized Erebine response") }
        guard (try? JSONEncoder().encode(message).count) ?? Int.max <= 65536 else { throw AIError.message("Erebine message exceeded the conversation limit") }
        return message
    }
}
