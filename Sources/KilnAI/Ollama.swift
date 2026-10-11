import Foundation
import KilnKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Explicit routing, never automatic fallback to another provider.
struct AIProviderClient {
    let metrics: AIProviderMetrics
    func stream(configuration: AIConfiguration, key: String, messages: [AIMessage], tools: [AITool],
                emit: @escaping @Sendable (AIProgress) -> Void) async throws -> AIMessage {
        switch configuration.provider {
        case .erebine:
            return try await ErebineClient(metrics: metrics).stream(configuration: configuration, key: key, messages: messages, tools: tools, emit: emit)
        case .ollama:
            try configuration.validate()
            try OllamaClient.validateProxyEnvironment(ProcessInfo.processInfo.environment)
            return try await metrics.measure {
                try await OllamaClient().stream(configuration: configuration, messages: messages, tools: tools, emit: emit)
            }
        }
    }
}

struct OllamaStreamDecoder {
    private var pending = Data()
    private var total = 0
    private var answer = "", thinking = ""
    private var calls: [AIToolCall] = []
    private(set) var done = false
    mutating func feed(_ bytes: Data, emit: @Sendable (AIProgress) -> Void) throws {
        total += bytes.count
        guard total <= 4_194_304 else { throw AIError.message("Ollama stream exceeded its size limit") }
        pending.append(bytes)
        while let end = pending.firstIndex(of: 10) {
            let line = Data(pending[..<end]); pending.removeSubrange(...end)
            if !line.isEmpty { try consume(line, emit: emit) }
        }
        guard pending.count <= 262144 else { throw AIError.message("Oversized Ollama event") }
    }
    private mutating func consume(_ data: Data, emit: @Sendable (AIProgress) -> Void) throws {
        guard !done, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] == nil, let finished = object["done"] as? Bool else {
            throw AIError.message("Invalid or failed Ollama stream")
        }
        if let message = object["message"] as? [String: Any] {
            guard message["role"] as? String == "assistant" else { throw AIError.message("Invalid Ollama role") }
            if let text = message["content"] as? String { answer += text; if !text.isEmpty { emit(.answer(text)) } }
            if let text = message["thinking"] as? String { thinking += text; if !text.isEmpty { emit(.reasoning(text)) } }
            for tool in message["tool_calls"] as? [[String: Any]] ?? [] {
                guard calls.count < 6, let f = tool["function"] as? [String: Any],
                      let name = f["name"] as? String, !name.isEmpty, name.utf8.count <= 128,
                      let arguments = f["arguments"] as? [String: Any] else { throw AIError.message("Invalid Ollama tool call") }
                let encoded = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
                guard encoded.count <= 4096 else { throw AIError.message("Oversized Ollama tool arguments") }
                calls.append(AIToolCall(id: UUID().uuidString, type: "function", function: .init(name: name, arguments: String(decoding: encoded, as: UTF8.self))))
            }
        }
        guard answer.utf8.count + thinking.utf8.count <= 65536 else { throw AIError.message("Ollama message exceeded its limit") }
        if finished {
            guard object["done_reason"] as? String == "stop" else { throw AIError.message("Ollama response incomplete; no partial tool executed") }
            done = true
        }
    }
    mutating func finish(emit: @Sendable (AIProgress) -> Void) throws -> AIMessage {
        if !pending.isEmpty { try consume(pending, emit: emit); pending.removeAll() }
        guard done else { throw AIError.message("Ollama stream interrupted; no partial tool executed") }
        var message = AIMessage(role: "assistant", content: answer, tool_calls: calls.isEmpty ? nil : calls)
        message.reasoning_content = thinking.isEmpty ? nil : thinking
        return message
    }
}

struct OllamaClient: Sendable {
    static func validateProxyEnvironment(_ environment: [String: String]) throws {
        // libcurl may use proxy environment variables independently of
        // URLSessionConfiguration. Do not mutate process-wide NO_PROXY or risk
        // sending local context to an intermediary, even with an exemption set.
        let proxyKeys = Set(["http_proxy", "https_proxy", "all_proxy"])
        guard !environment.contains(where: { proxyKeys.contains($0.key.lowercased()) && !$0.value.isEmpty }) else {
            throw AIError.message("Local Ollama is disabled while proxy environment variables are configured; launch Kiln without HTTP_PROXY, HTTPS_PROXY or ALL_PROXY (including lowercase variants)")
        }
    }
    func request(configuration: AIConfiguration, messages: [AIMessage], tools: [AITool]) throws -> URLRequest {
        try configuration.validate()
        guard configuration.provider == .ollama else { throw AIError.message("Wrong provider for Ollama transport") }
        var names: [String: String] = [:]
        let normalized: [[String: Any]] = try messages.map { message in
            var item: [String: Any] = ["role": message.role, "content": message.content ?? ""]
            if let reasoning = message.reasoning_content { item["thinking"] = reasoning }
            if let calls = message.tool_calls {
                item["tool_calls"] = try calls.map { call -> [String: Any] in
                    names[call.id] = call.function.name
                    guard let data = call.function.arguments.data(using: .utf8),
                          let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.message("Invalid local tool arguments") }
                    return ["type": "function", "function": ["name": call.function.name, "arguments": arguments]]
                }
            }
            if message.role == "tool" {
                guard let id = message.tool_call_id, let name = names[id] else { throw AIError.message("Orphaned local tool result") }
                item["tool_name"] = name
            }
            return item
        }
        let schemas = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tools))
        var request = URLRequest(url: URL(string: configuration.baseURL)!.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"; request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": configuration.model, "messages": normalized,
            "tools": schemas, "stream": true, "keep_alive": "1m", "options": ["num_predict": 4096, "num_ctx": 8192]])
        return request
    }
    func stream(configuration: AIConfiguration, messages: [AIMessage], tools: [AITool],
                sessionConfiguration: URLSessionConfiguration? = nil,
                emit: @escaping @Sendable (AIProgress) -> Void) async throws -> AIMessage {
        try Self.validateProxyEnvironment(ProcessInfo.processInfo.environment)
        let request = try request(configuration: configuration, messages: messages, tools: tools)
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        let delegate = StreamingDelegate(pair.continuation, mimeType: "application/x-ndjson")
        let options = sessionConfiguration ?? URLSessionConfiguration.ephemeral
        options.httpCookieStorage = nil; options.urlCache = nil; options.timeoutIntervalForResource = 120
        // Local mode must not forward runtime context through a configured proxy.
        options.connectionProxyDictionary = [:]
        let session = URLSession(configuration: options, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        defer { task.cancel(); session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation(); task.resume()
            var decoder = OllamaStreamDecoder()
            for try await bytes in pair.stream {
                try Task.checkCancellation(); try decoder.feed(bytes, emit: emit)
                if decoder.done { break }
            }
            try Task.checkCancellation()
            return try decoder.finish(emit: emit)
        } onCancel: { task.cancel() }
    }
}
