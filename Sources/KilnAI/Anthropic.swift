import Foundation
import KilnKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Native Messages API adapter. Extended thinking is disabled until signed
/// thinking blocks can be preserved losslessly across tool-result turns.
public struct AnthropicClient: Sendable {
    public let metrics: AIProviderMetrics
    public init(metrics: AIProviderMetrics = AIProviderMetrics()) { self.metrics = metrics }

    static func request(configuration: AIConfiguration, key: String, messages: [AIMessage], tools: [AITool]) throws -> URLRequest {
        try configuration.validate()
        guard configuration.provider == .anthropic else { throw AIError.message("Wrong Messages provider") }
        var system: [String] = []
        var history: [[String: Any]] = []
        var pending = Set<String>()
        for message in messages {
            if message.role == "system" {
                guard history.isEmpty else { throw AIError.message("Claude system instructions must precede conversation history") }
                if let text = message.content { system.append(text) }
                continue
            }
            var blocks: [[String: Any]] = []
            let role: String
            switch message.role {
            case "assistant":
                guard pending.isEmpty else { throw AIError.message("Claude history contains unanswered tool calls") }
                role = "assistant"
                if let text = message.content, !text.isEmpty { blocks.append(["type": "text", "text": text]) }
                for call in message.tool_calls ?? [] {
                    guard call.type == "function", !call.id.isEmpty, pending.insert(call.id).inserted,
                          let input = try? JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8)) as? [String: Any] else {
                        throw AIError.message("Invalid Claude tool history")
                    }
                    blocks.append(["type": "tool_use", "id": call.id, "name": call.function.name, "input": input])
                }
            case "tool":
                role = "user"
                guard let id = message.tool_call_id, pending.remove(id) != nil else { throw AIError.message("Unmatched Claude tool result") }
                blocks.append(["type": "tool_result", "tool_use_id": id, "content": message.content ?? ""])
            case "user":
                guard pending.isEmpty else { throw AIError.message("Claude history contains unanswered tool calls") }
                role = "user"
                blocks.append(["type": "text", "text": message.content ?? ""])
            default: throw AIError.message("Unsupported Claude message role")
            }
            guard !blocks.isEmpty else { throw AIError.message("Empty Claude message") }
            if history.last?["role"] as? String == role {
                var last = history.removeLast()
                last["content"] = (last["content"] as? [[String: Any]] ?? []) + blocks
                history.append(last)
            } else { history.append(["role": role, "content": blocks]) }
        }
        guard pending.isEmpty, !history.isEmpty else { throw AIError.message("Incomplete Claude conversation history") }
        let mappedTools = try tools.map { tool -> [String: Any] in
            let schema = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.function.parameters))
            return ["name": tool.function.name, "description": tool.function.description, "input_schema": schema]
        }
        var body: [String: Any] = ["model": configuration.model, "messages": history,
                                  "max_tokens": 4096, "stream": true, "thinking": ["type": "disabled"]]
        if !system.isEmpty { body["system"] = system.joined(separator: "\n\n") }
        if !mappedTools.isEmpty { body["tools"] = mappedTools }
        var request = URLRequest(url: URL(string: configuration.baseURL)!.appendingPathComponent("messages"))
        request.httpMethod = "POST"; request.timeoutInterval = 90
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    public func stream(configuration: AIConfiguration, key: String, messages: [AIMessage], tools: [AITool],
                       emit: @escaping @Sendable (AIProgress) -> Void) async throws -> AIMessage {
        let request = try Self.request(configuration: configuration, key: key, messages: messages, tools: tools)
        return try await ProviderRetry.run(metrics: metrics, emit: emit) {
            try await streamAttempt(request: request, emit: emit)
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
            var decoder = AnthropicStreamDecoder()
            do {
                for try await bytes in pair.stream {
                    try Task.checkCancellation()
                    try decoder.feed(bytes, emit: emit)
                    if decoder.done { break }
                }
                try Task.checkCancellation()
                return try decoder.message()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: { task.cancel() }
    }
}

struct AnthropicStreamDecoder {
    private var pending = Data()
    private var event: [String] = []
    private var eventName: String?
    private var total = 0
    private var started = false
    private var stopReason: String?
    private var usage = AIProviderUsage()
    private var answer = ""
    private struct Block { let type: String; var id = ""; var name = ""; var arguments = ""; var closed = false }
    private var blocks: [Int: Block] = [:]
    private(set) var done = false
    private func invalid() -> AIError { .message("Claude returned an invalid or incomplete stream; no partial tool call executed") }
    mutating func feed(_ data: Data, emit: @Sendable (AIProgress) -> Void) throws {
        total += data.count
        guard total <= 4_194_304 else { throw invalid() }
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            guard let text = String(data: pending[..<newline], encoding: .utf8) else { throw invalid() }
            pending.removeSubrange(...newline)
            let line = text.hasSuffix("\r") ? String(text.dropLast()) : text
            if line.isEmpty { try consume(emit: emit) }
            else if line.hasPrefix("data:") { event.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
            else if line.hasPrefix("event:") { eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            guard event.reduce(0, { $0 + $1.utf8.count }) <= 262144 else { throw invalid() }
        }
        guard pending.count <= 262144 else { throw invalid() }
    }
    private mutating func consume(emit: @Sendable (AIProgress) -> Void) throws {
        defer { event.removeAll(keepingCapacity: true); eventName = nil }
        guard !event.isEmpty else { return }
        guard !done, let object = try? JSONSerialization.jsonObject(with: Data(event.joined(separator: "\n").utf8)) as? [String: Any],
              let type = object["type"] as? String, eventName == nil || eventName == type else { throw invalid() }
        if type == "ping" { return }
        if type == "error" { throw AIError.message("Claude reported a stream error; no partial tool call executed") }
        if type == "message_start" {
            guard !started, let message = object["message"] as? [String: Any], message["role"] as? String == "assistant",
                  let content = message["content"] as? [Any], content.isEmpty else { throw invalid() }
            if let reported = message["usage"] as? [String: Any] { usage.update(.anthropic(reported)) }
            started = true; return
        }
        guard started else { throw invalid() }
        switch type {
        case "content_block_start":
            guard stopReason == nil, let index = object["index"] as? Int, (0..<32).contains(index), blocks[index] == nil,
                  let content = object["content_block"] as? [String: Any], let kind = content["type"] as? String else { throw invalid() }
            var block = Block(type: kind)
            if kind == "text" {
                guard let text = content["text"] as? String else { throw invalid() }
                answer += text; if !text.isEmpty { emit(.answer(text)) }
            } else if kind == "tool_use" {
                guard blocks.values.filter({ $0.type == "tool_use" }).count < 6,
                      let id = content["id"] as? String, !id.isEmpty, id.utf8.count <= 256,
                      !blocks.values.contains(where: { $0.id == id }),
                      let name = content["name"] as? String, !name.isEmpty, name.utf8.count <= 128,
                      let input = content["input"] as? [String: Any], input.isEmpty else { throw invalid() }
                block.id = id; block.name = name
            } else { throw invalid() }
            blocks[index] = block
        case "content_block_delta":
            guard stopReason == nil, let index = object["index"] as? Int, var block = blocks[index], !block.closed,
                  let delta = object["delta"] as? [String: Any] else { throw invalid() }
            if block.type == "text", delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                answer += text; emit(.answer(text))
            } else if block.type == "tool_use", delta["type"] as? String == "input_json_delta", let fragment = delta["partial_json"] as? String {
                block.arguments += fragment
                guard block.arguments.utf8.count <= 4096 else { throw invalid() }
            } else { throw invalid() }
            blocks[index] = block
        case "content_block_stop":
            guard let index = object["index"] as? Int, var block = blocks[index], !block.closed else { throw invalid() }
            if block.type == "tool_use" {
                if block.arguments.isEmpty { block.arguments = "{}" }
                guard (try? JSONSerialization.jsonObject(with: Data(block.arguments.utf8))) is [String: Any] else { throw invalid() }
            }
            block.closed = true; blocks[index] = block
        case "message_delta":
            if let reported = object["usage"] as? [String: Any] { usage.update(.anthropic(reported)) }
            guard blocks.values.allSatisfy({ $0.closed }), let delta = object["delta"] as? [String: Any] else { throw invalid() }
            if let reason = delta["stop_reason"] as? String {
                guard stopReason == nil, ["end_turn", "stop_sequence", "tool_use"].contains(reason) else { throw invalid() }
                stopReason = reason
            }
        case "message_stop":
            guard stopReason != nil, blocks.values.allSatisfy({ $0.closed }) else { throw invalid() }
            let hasTools = blocks.values.contains(where: { $0.type == "tool_use" })
            guard hasTools == (stopReason == "tool_use") else { throw invalid() }
            done = true
        default: break // Forward-compatible unrelated events cannot authorize tools.
        }
        guard answer.utf8.count <= 65536 else { throw invalid() }
    }
    func message() throws -> AIMessage {
        guard done else { throw invalid() }
        let calls = blocks.keys.sorted().compactMap { index -> AIToolCall? in
            let block = blocks[index]!
            guard block.type == "tool_use" else { return nil }
            return AIToolCall(id: block.id, type: "function", function: .init(name: block.name, arguments: block.arguments))
        }
        var message = AIMessage(role: "assistant", content: answer, tool_calls: calls.isEmpty ? nil : calls)
        message.usage = usage.isEmpty ? nil : usage
        return message
    }
}
