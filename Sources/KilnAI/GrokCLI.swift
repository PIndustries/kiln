import Foundation
import KilnKit

/// A distinct external-agent backend. Never route an API profile into a host CLI.
/// The host supplies an isolated process supervisor; this package deliberately
/// does not launch Grok with the Kiln daemon's filesystem or environment access.
public struct GrokCLIRequest: Sendable {
    public let prompt: String
    public let model: String
    public let sessionID: UUID
    public let timeoutSeconds: Double
    public init(prompt: String, model: String, sessionID: UUID = UUID(), timeoutSeconds: Double = 120) throws {
        guard !prompt.isEmpty, prompt.utf8.count <= 65_536, !prompt.contains("\0"),
              !model.isEmpty, model.utf8.count <= 256, !model.contains("\0"),
              timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 600 else {
            throw AIError.message("Invalid Grok headless request")
        }
        self.prompt = prompt; self.model = model; self.sessionID = sessionID; self.timeoutSeconds = timeoutSeconds
    }
    /// Pass each element as one argv entry, never concatenate into a shell command.
    /// Tool flags are defense in depth, not a substitute for the worker sandbox.
    /// Vendor sandboxing is off because the supervisor applies OS isolation first.
    public var arguments: [String] {
        ["--no-auto-update", "--single", prompt, "--model", model,
         "--session-id", sessionID.uuidString.lowercased(), "--output-format", "streaming-json",
         "--tools", "", "--no-subagents", "--no-plan", "--disable-web-search",
         "--permission-mode", "dontAsk", "--sandbox", "off", "--max-turns", "1"]
    }
}

public enum GrokCLIOutput: Sendable {
    case stdout(Data)
    /// Report only the count. Raw stderr may contain credentials or local paths.
    case stderrBytes(Int)
    case exited(Int32)
}

/// A supervisor must enforce its own deadline, isolate the entire process tree,
/// provide a clean configuration/home, and explicitly provision authentication.
/// cancel must synchronously initiate process-tree termination and finish output.
/// A workspace directory or Grok permission flags alone do not meet this contract.
public struct GrokCLIExecution: Sendable {
    public let output: AsyncThrowingStream<GrokCLIOutput, Error>
    public let cancel: @Sendable () -> Void
    public init(output: AsyncThrowingStream<GrokCLIOutput, Error>, cancel: @escaping @Sendable () -> Void) {
        self.output = output; self.cancel = cancel
    }
}

public struct GrokCLIWorker: Sendable {
    public typealias IsolatedSupervisor = @Sendable (GrokCLIRequest) async throws -> GrokCLIExecution
    private let supervisor: IsolatedSupervisor?
    public init(isolatedSupervisor: IsolatedSupervisor? = nil) { supervisor = isolatedSupervisor }
    public var available: Bool { supervisor != nil }
    public func run(_ request: GrokCLIRequest, emit: @escaping @Sendable (AIProgress) -> Void) async throws -> AIMessage {
        guard let supervisor else {
            throw AIError.message("Grok headless requires an isolated worker supervisor; direct host CLI execution is disabled")
        }
        try Task.checkCancellation()
        let execution = try await supervisor(request)
        return try await withTaskCancellationHandler {
            defer { execution.cancel() }
            return try await withThrowingTaskGroup(of: AIMessage.self) { group in
                group.addTask {
                    var decoder = GrokCLIStreamDecoder()
                    var stderrCount = 0
                    var exited = false
                    for try await event in execution.output {
                        try Task.checkCancellation()
                        guard !exited else { throw AIError.message("Unexpected output after Grok exit") }
                        switch event {
                        case .stdout(let bytes): try decoder.feed(bytes, emit: emit)
                        case .stderrBytes(let count):
                            guard count >= 0, count <= 65_536 - stderrCount else {
                                throw AIError.message("Grok diagnostic output exceeded its limit")
                            }
                            stderrCount += count
                        case .exited(let status):
                            guard status == 0 else { throw AIError.message("Grok headless worker failed (exit \(status)); diagnostics withheld") }
                            exited = true
                        }
                    }
                    guard exited else { throw AIError.message("Grok worker disconnected without an exit receipt") }
                    return try decoder.finish()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(request.timeoutSeconds))
                    execution.cancel()
                    throw AIError.message("Grok headless worker timed out")
                }
                defer { group.cancelAll(); execution.cancel() }
                guard let result = try await group.next() else { throw AIError.message("Missing Grok worker result") }
                return result
            }
        } onCancel: { execution.cancel() }
    }
}

/// ACP session-update NDJSON used by Grok's streaming-json output. Assistant text
/// is content, never interpreted as Kiln commands or tool requests.
struct GrokCLIStreamDecoder {
    private var pending = Data()
    private var total = 0
    private var answer = ""
    mutating func feed(_ data: Data, emit: @Sendable (AIProgress) -> Void) throws {
        guard data.count <= 4_194_304 - total else { throw AIError.message("Grok output exceeded its limit") }
        total += data.count; pending.append(data)
        while let end = pending.firstIndex(of: 10) {
            let line = Data(pending[..<end]); pending.removeSubrange(...end)
            if !line.isEmpty { try consume(line, emit: emit) }
        }
        guard pending.count <= 262_144 else { throw AIError.message("Oversized Grok event") }
    }
    private mutating func consume(_ data: Data, emit: @Sendable (AIProgress) -> Void) throws {
        guard data.count <= 262_144,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.message("Invalid Grok streaming event")
        }
        guard object["type"] as? String != "error", object["error"] == nil else {
            throw AIError.message("Grok headless returned an error; provider diagnostics withheld")
        }
        let params = object["params"] as? [String: Any]
        let update = (params?["update"] as? [String: Any]) ?? (object["update"] as? [String: Any]) ?? object
        guard let kind = update["sessionUpdate"] as? String else { throw AIError.message("Unknown Grok streaming envelope") }
        switch kind {
        case "agent_message_chunk":
            guard let content = update["content"] as? [String: Any], content["type"] as? String == "text",
                  let text = content["text"] as? String, text.utf8.count <= 65_536 - answer.utf8.count else {
                throw AIError.message("Invalid or oversized Grok text")
            }
            answer += text; if !text.isEmpty { emit(.answer(text)) }
        case "agent_thought_chunk":
            // Display operational status only; never persist private reasoning.
            emit(.status("Grok worker is processing"))
        case "tool_call", "tool_call_update":
            throw AIError.message("Grok attempted autonomous tool execution; isolated worker stopped")
        case "usage_update", "session_info_update", "current_mode_update", "available_commands_update": break
        default: throw AIError.message("Unsupported Grok streaming event")
        }
    }
    mutating func finish() throws -> AIMessage {
        // Require complete NDJSON frames; no guessed completion from partial text.
        guard pending.isEmpty, !answer.isEmpty else { throw AIError.message("Incomplete Grok response") }
        return AIMessage(role: "assistant", content: answer)
    }
}
