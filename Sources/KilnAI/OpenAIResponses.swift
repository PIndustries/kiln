import Foundation
import KilnKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Responses output items must be replayed unchanged in stateless tool rounds,
/// including opaque encrypted reasoning. Only public summaries are displayed.
struct OpenAIResponsesDecoder {
    private var pending = Data()
    private var lines: [String] = []
    private var total = 0
    private var displayedBytes = 0
    private var result: AIMessage?
    private let reconstructCompletedOutput: Bool
    private var completedItems: [Int: Data] = [:]
    private(set) var done = false
    init(reconstructCompletedOutput: Bool = false) { self.reconstructCompletedOutput = reconstructCompletedOutput }

    mutating func feed(_ bytes: Data, emit: @Sendable (AIProgress) -> Void) throws {
        total += bytes.count
        guard total <= 4_194_304 else { throw AIError.message("Responses stream exceeded its size limit") }
        pending.append(bytes)
        while let newline = pending.firstIndex(of: 10) {
            guard let line = String(data: pending[..<newline], encoding: .utf8) else { throw AIError.message("Invalid Responses stream encoding") }
            pending.removeSubrange(...newline)
            let clean = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if clean.isEmpty { try consume(emit: emit) }
            else if clean.hasPrefix("data:") { lines.append(String(clean.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
        }
        guard pending.count <= 262144 else { throw AIError.message("Oversized Responses stream event") }
    }

    private mutating func consume(emit: @Sendable (AIProgress) -> Void) throws {
        guard !lines.isEmpty else { return }
        let payload = lines.joined(separator: "\n"); lines.removeAll(keepingCapacity: true)
        guard !done, let bytes = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let type = event["type"] as? String else { throw AIError.message("Invalid Responses stream event") }
        switch type {
        case "error", "response.failed", "response.incomplete":
            let response = event["response"] as? [String: Any]
            let error = response?["error"] as? [String: Any] ?? event["error"] as? [String: Any]
            if let failure = ProviderPlanFailure(code: error?["code"] as? String ?? event["code"] as? String) { throw failure }
            throw AIError.message("Responses response failed or was incomplete; no partial tool call executed")
        case "response.output_text.delta", "response.refusal.delta", "response.reasoning_summary_text.delta":
            guard let delta = event["delta"] as? String else { throw AIError.message("Invalid Responses text delta") }
            displayedBytes += delta.utf8.count
            guard displayedBytes <= 65536 else { throw AIError.message("Responses message exceeded its limit") }
            if type == "response.reasoning_summary_text.delta" { emit(.reasoning(delta)) }
            else { emit(.answer(delta)) }
        case "response.output_item.done" where reconstructCompletedOutput:
            guard let index = AIProviderUsage.count(event["output_index"]), index < 64,
                  completedItems[Int(index)] == nil, let item = event["item"] as? [String: Any] else {
                throw AIError.message("Invalid completed Responses output item")
            }
            let encoded = try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys])
            guard encoded.count <= 65536 else { throw AIError.message("Responses output item exceeded its limit") }
            completedItems[Int(index)] = encoded
        case "response.completed":
            guard let response = event["response"] as? [String: Any], response["status"] as? String == "completed",
                  response["error"] == nil || response["error"] is NSNull,
                  let output = response["output"] as? [[String: Any]], output.count <= 64 else {
                throw AIError.message("Responses response did not complete successfully")
            }
            var completedOutput = output
            if reconstructCompletedOutput, output.isEmpty {
                // ChatGPT direct streams can emit full output_item.done records
                // and an empty terminal output array. Stage complete items only;
                // fragments never become calls, and nothing is returned until
                // the response.completed event confirms successful completion.
                guard !completedItems.isEmpty, completedItems.keys.sorted() == Array(0..<completedItems.count) else {
                    throw AIError.message("Responses completed without a complete output sequence")
                }
                completedOutput = try completedItems.keys.sorted().map { index in
                    guard let item = try JSONSerialization.jsonObject(with: completedItems[index]!) as? [String: Any] else {
                        throw AIError.message("Invalid completed Responses output item")
                    }
                    return item
                }
            }
            var answer = ""; var calls: [AIToolCall] = []; var replay: [String] = []; var ids = Set<String>()
            for item in completedOutput {
                if let status = item["status"] as? String, status != "completed" {
                    throw AIError.message("Incomplete Responses output item")
                }
                switch item["type"] as? String {
                case "message":
                    guard item["role"] as? String == "assistant", let content = item["content"] as? [[String: Any]] else {
                        throw AIError.message("Invalid Responses message")
                    }
                    for part in content {
                        if part["type"] as? String == "output_text", let text = part["text"] as? String { answer += text }
                        else if part["type"] as? String == "refusal", let text = part["refusal"] as? String { answer += text }
                        else { throw AIError.message("Unsupported Responses message content") }
                    }
                case "function_call":
                    guard item["namespace"] == nil || item["namespace"] is NSNull || item["namespace"] as? String == "kiln" else { throw AIError.message("Unsupported Responses tool namespace") }
                    guard let id = item["call_id"] as? String, !id.isEmpty, id.utf8.count <= 256, ids.insert(id).inserted,
                          let name = item["name"] as? String, !name.isEmpty, name.utf8.count <= 128,
                          let arguments = item["arguments"] as? String, arguments.utf8.count <= 4096,
                          let argumentData = arguments.data(using: .utf8),
                          (try? JSONSerialization.jsonObject(with: argumentData)) is [String: Any], calls.count < 6 else {
                        throw AIError.message("Invalid Responses function call")
                    }
                    calls.append(AIToolCall(id: id, type: "function", function: .init(name: name, arguments: arguments)))
                case "reasoning": break
                default: throw AIError.message("Unsupported Responses output item")
                }
                replay.append(String(decoding: try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]), as: UTF8.self))
            }
            var message = AIMessage(role: "assistant", content: answer, tool_calls: calls.isEmpty ? nil : calls)
            message.providerItems = replay
            if let usage = response["usage"] as? [String: Any] {
                let normalized = AIProviderUsage.responses(usage)
                message.usage = normalized.isEmpty ? nil : normalized
            }
            guard try JSONEncoder().encode(message).count <= 65536 else { throw AIError.message("Responses message exceeded the conversation limit") }
            result = message; done = true
        default: break // Lifecycle and argument fragments are not executable calls.
        }
    }
    func message() throws -> AIMessage {
        guard done, let result else { throw AIError.message("Responses stream interrupted; no partial tool call executed") }
        return result
    }
}

public struct OpenAIResponsesClient: Sendable {
    public let metrics: AIProviderMetrics
    public init(metrics: AIProviderMetrics = AIProviderMetrics()) { self.metrics = metrics }

    static func makeRequest(configuration: AIConfiguration, key: String, messages: [AIMessage], tools: [AITool]) throws -> URLRequest {
        try configuration.validate()
        guard configuration.provider == .openai || configuration.provider == .grok || configuration.provider == .chatgpt else { throw AIError.message("Wrong Responses provider") }
        var input: [[String: Any]] = []
        for message in messages {
            if message.role == "assistant", let replay = message.providerItems, !replay.isEmpty {
                for encoded in replay {
                    guard let data = encoded.data(using: .utf8), let item = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          ["message", "reasoning", "function_call"].contains(item["type"] as? String ?? "") else { throw AIError.message("Invalid Responses conversation item") }
                    input.append(item)
                }
            } else if message.role == "tool" {
                guard let id = message.tool_call_id, !id.isEmpty else { throw AIError.message("Missing Responses tool call identifier") }
                input.append(["type": "function_call_output", "call_id": id, "output": message.content ?? ""])
            } else {
                guard ["system", "developer", "user", "assistant"].contains(message.role) else { throw AIError.message("Invalid Responses conversation role") }
                if let content = message.content, !content.isEmpty { input.append(["role": configuration.provider == .chatgpt && message.role == "system" ? "developer" : message.role, "content": content]) }
                for call in message.tool_calls ?? [] {
                    input.append(["type": "function_call", "call_id": call.id, "name": call.function.name, "arguments": call.function.arguments])
                }
            }
        }
        let toolObjects: [[String: Any]] = try tools.map { tool in
            let parameters = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.function.parameters))
            return ["type": "function", "name": tool.function.name, "description": tool.function.description, "parameters": parameters, "strict": true]
        }
        var body: [String: Any] = ["model": configuration.model, "input": input, "tools": toolObjects,
                                   "stream": true, "store": false, "max_output_tokens": 4096,
                                   "include": ["reasoning.encrypted_content"], "parallel_tool_calls": true]
        if configuration.provider == .chatgpt {
            body.removeValue(forKey: "max_output_tokens")
            body["tools"] = toolObjects.isEmpty ? [] : [["type": "namespace", "name": "kiln", "description": "Authorized Kiln operations", "tools": toolObjects]]
        }
        var request = URLRequest(url: URL(string: configuration.baseURL)!.appendingPathComponent("responses"))
        request.httpMethod = "POST"; request.timeoutInterval = 90
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    public func stream(configuration: AIConfiguration, key: String, messages: [AIMessage], tools: [AITool],
                       emit: @escaping @Sendable (AIProgress) -> Void) async throws -> AIMessage {
        let request = try Self.makeRequest(configuration: configuration, key: key, messages: messages, tools: tools)
        return try await ProviderRetry.run(metrics: metrics, emit: emit) {
            try await streamAttempt(request: request, allowMissingContentType: configuration.provider == .chatgpt,
                                    reconstructCompletedOutput: configuration.provider == .chatgpt, emit: emit)
        }
    }
    func streamAttempt(request: URLRequest, configuration: URLSessionConfiguration? = nil,
                       allowMissingContentType: Bool = false,
                       reconstructCompletedOutput: Bool = false,
                       emit: @escaping @Sendable (AIProgress) -> Void) async throws -> AIMessage {
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        // The ChatGPT direct route can omit Content-Type on a valid SSE response
        // (observed in live acceptance). Only that route permits absence. Explicit
        // wrong types still fail, and bounded SSE parsing plus response.completed
        // remain mandatory before returning text or executable tools.
        let delegate = StreamingDelegate(pair.continuation, allowMissingContentType: allowMissingContentType)
        let options = configuration ?? URLSessionConfiguration.ephemeral
        options.httpCookieStorage = nil; options.urlCache = nil; options.timeoutIntervalForResource = 120
        let session = URLSession(configuration: options, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        defer { task.cancel(); session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation(); task.resume()
            do {
                var decoder = OpenAIResponsesDecoder(reconstructCompletedOutput: reconstructCompletedOutput)
                for try await bytes in pair.stream {
                    try Task.checkCancellation(); try decoder.feed(bytes, emit: emit)
                    if decoder.done { break }
                }
                try Task.checkCancellation(); return try decoder.message()
            } catch { if Task.isCancelled { throw CancellationError() }; throw error }
        } onCancel: { task.cancel() }
    }
}
