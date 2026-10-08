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
        let data = try await BoundedCompletionHTTP.data(for: request, configuration: options)
        guard data.count <= 4_194_304, let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let message = decoded.choices.first?.message, message.role == "assistant" else { throw AIError.message("Invalid or oversized Erebine response") }
        guard (try? JSONEncoder().encode(message).count) ?? Int.max <= 65536 else { throw AIError.message("Erebine message exceeded the conversation limit") }
        return message
    }
}
