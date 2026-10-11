import Foundation
import KilnKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Incremental SSE parser: transport packets may split UTF-8, JSON and event boundaries.
struct ErebineStreamDecoder {
    private var pending = Data()
    private var event: [String] = []
    private var total = 0
    private var answer = ""
    private var reasoning = ""
    private struct Call { var id = ""; var name = ""; var arguments = "" }
    private var calls: [Int: Call] = [:]
    private(set) var done = false
    private var finished = false
    mutating func feed(_ data: Data, emit: @Sendable (AIProgress) -> Void) throws {
        total += data.count
        guard total <= 4_194_304 else { throw AIError.message("Erebine stream exceeded its size limit") }
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let lineData = pending[..<newline]
            guard let text = String(data: lineData, encoding: .utf8) else { throw AIError.message("Invalid stream encoding") }
            pending.removeSubrange(...newline)
            let line = text.hasSuffix("\r") ? String(text.dropLast()) : text
            if line.isEmpty { try consume(emit: emit) }
            else if line.hasPrefix("data:") { event.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
        }
        guard pending.count <= 262144 else { throw AIError.message("Oversized stream event") }
    }
    private mutating func consume(emit: @Sendable (AIProgress) -> Void) throws {
        guard !event.isEmpty else { return }
        let payload = event.joined(separator: "\n"); event.removeAll(keepingCapacity: true)
        if payload == "[DONE]" { done = true; return }
        guard !done, let data = payload.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["error"] == nil else {
            throw AIError.message("Erebine reported an invalid or failed stream")
        }
        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else { return }
        if let finish = first["finish_reason"] as? String {
            guard ["stop", "tool_calls"].contains(finish) else { throw AIError.message("Erebine response was cut short; no partial tool call executed") }
            finished = true
        }
        guard let delta = first["delta"] as? [String: Any] else { return }
        if let text = delta["content"] as? String ?? delta["refusal"] as? String, !text.isEmpty {
            answer += text; emit(.answer(text))
        }
        // Current Erebine API documents both names; never concatenate duplicate aliases.
        if let text = delta["reasoning_content"] as? String ?? delta["reasoning"] as? String, !text.isEmpty {
            reasoning += text; emit(.reasoning(text))
        }
        for fragment in delta["tool_calls"] as? [[String: Any]] ?? [] {
            guard let index = fragment["index"] as? Int, (0..<6).contains(index) else { throw AIError.message("Invalid streamed tool index") }
            var call = calls[index] ?? Call()
            if let id = fragment["id"] as? String { call.id += id }
            if let function = fragment["function"] as? [String: Any] {
                call.name += function["name"] as? String ?? ""
                call.arguments += function["arguments"] as? String ?? ""
            }
            guard call.id.count <= 256, call.name.count <= 128, call.arguments.utf8.count <= 4096 else { throw AIError.message("Oversized streamed tool call") }
            calls[index] = call
        }
        guard answer.utf8.count + reasoning.utf8.count <= 65536 else { throw AIError.message("Erebine message exceeded its limit") }
    }
    func message() throws -> AIMessage {
        guard done, finished else { throw AIError.message("Erebine stream interrupted; no partial tool call executed") }
        let tools = try calls.keys.sorted().map { index -> AIToolCall in
            let call = calls[index]!
            guard !call.id.isEmpty, !call.name.isEmpty else { throw AIError.message("Incomplete streamed tool call") }
            return AIToolCall(id: call.id, type: "function", function: .init(name: call.name, arguments: call.arguments))
        }
        var result = AIMessage(role: "assistant", content: answer, tool_calls: tools.isEmpty ? nil : tools)
        result.reasoning_content = reasoning.isEmpty ? nil : reasoning
        return result
    }
}

// URLSession serializes callbacks on its delegate queue.
final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var rejection: ProviderFailure?
    private var rejected = false
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    init(_ continuation: AsyncThrowingStream<Data, Error>.Continuation) { self.continuation = continuation }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            continuation.finish(throwing: AIError.message("Invalid Erebine stream response")); completionHandler(.cancel); return
        }
        if http.statusCode != 200 {
            rejection = ProviderFailure(response: http)
            if http.expectedContentLength > Int64(ProviderFailure.maximumBytes) {
                rejected = true; continuation.finish(throwing: rejection!); completionHandler(.cancel)
            } else { completionHandler(.allow) }
            return
        }
        guard http.mimeType == "text/event-stream" else {
            continuation.finish(throwing: AIError.message("Erebine returned an invalid stream content type")); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !rejected else { return }
        if rejection != nil {
            if !rejection!.append(data) {
                rejected = true; continuation.finish(throwing: rejection!); dataTask.cancel()
            }
            return
        }
        if case .dropped = continuation.yield(data) {
            continuation.finish(throwing: AIError.message("Erebine stream consumer fell behind")); dataTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !rejected else { return }
        if let rejection { continuation.finish(throwing: rejection); return }
        if let error { continuation.finish(throwing: ProviderTransportFailure(error)) }
        else { continuation.finish() }
    }
}

extension ErebineClient {
    public func stream(configuration: AIConfiguration, key: String, messages: [AIMessage], tools: [AITool],
                       emit: @escaping @Sendable (AIProgress) -> Void) async throws -> AIMessage {
        try configuration.validate()
        struct Request: Encodable {
            let model: String; let messages: [AIMessage]; let tools: [AITool]
            let stream = true; let store = false; let max_completion_tokens = 4096
            let parallel_tool_calls = true
            var tool_choice: String { tools.isEmpty ? "none" : "auto" }
        }
        var request = URLRequest(url: URL(string: configuration.baseURL)!.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"; request.timeoutInterval = 90
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(Request(model: configuration.model, messages: messages, tools: tools))
        let preparedRequest = request
        return try await ProviderRetry.run(metrics: metrics, emit: emit) {
            try await streamAttempt(request: preparedRequest, emit: emit)
        }
    }
    func streamAttempt(request: URLRequest, configuration: URLSessionConfiguration? = nil,
                       emit: @escaping @Sendable (AIProgress) -> Void) async throws -> AIMessage {
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        let delegate = StreamingDelegate(pair.continuation)
        let options = configuration ?? URLSessionConfiguration.ephemeral
        options.httpCookieStorage = nil; options.urlCache = nil; options.timeoutIntervalForResource = 120
        let session = URLSession(configuration: options, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        defer { task.cancel(); session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation(); task.resume()
            var decoder = ErebineStreamDecoder()
            do {
                for try await bytes in pair.stream {
                    try Task.checkCancellation()
                    try decoder.feed(bytes, emit: emit)
                    if decoder.done { break }
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
            try Task.checkCancellation()
            return try decoder.message()
        } onCancel: { task.cancel() }
    }
}
