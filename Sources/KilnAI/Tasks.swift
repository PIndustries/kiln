import Foundation
import KilnKit

public actor AITasks {
    public struct Record: Codable, Sendable {
        public let id: String
        public let prompt: String
        public var state: String
        public var output: String
        public let created: Date
    }
    public typealias Runner = @Sendable (String, String, @escaping @Sendable (AIProgress) -> Void) async throws -> String
    private struct Index: Codable { var concurrency = 4; var records: [Record] = [] }
    private let directory: URL
    private var index = Index()
    private var loaded = false
    private var persistenceUncertain = false
    private var runners: [String: Runner] = [:]
    private var running: [String: Task<Void, Never>] = [:]
    private var watchers: [String: [UUID: AsyncStream<String>.Continuation]] = [:]
    public init(directory: URL) { self.directory = directory }
    private func load() throws {
        guard !persistenceUncertain else { throw AIError.message("Task state commit is uncertain; restart and reconcile before retrying") }
        guard !loaded else { return }
        let file = directory.appendingPathComponent("ai-tasks.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard data.count <= 16_777_216 else { throw AIError.message("AI task index exceeds size limit") }
            index = try JSONDecoder().decode(Index.self, from: data)
            guard (1...48).contains(index.concurrency), index.records.count <= 200 else { throw AIError.message("Invalid AI task index") }
            for i in index.records.indices where ["queued", "running"].contains(index.records[i].state) {
                index.records[i].state = "interrupted"
                index.records[i].output = "Runtime restarted. Task was not automatically replayed."
            }
            try save()
        }
        loaded = true
    }
    private func save() throws {
        guard !persistenceUncertain else { throw AIError.message("Task state requires restart reconciliation") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("ai-tasks.json")
        let bytes = try JSONEncoder().encode(index)
        guard bytes.count <= 16_777_216 else { throw AIError.message("AI task history exceeds 16 MiB; remove completed tasks") }
        do { try KilnStateFile.write(bytes, to: url) }
        catch let error as KilnStateFile.CommitUncertain { persistenceUncertain = true; throw error }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func submit(_ prompt: String, runner: @escaping Runner) throws -> String {
        try load()
        guard !prompt.isEmpty, prompt.utf8.count <= 8192 else { throw AIError.message("Task prompt must be 1–8192 bytes") }
        guard index.records.count < 200 else { throw AIError.message("Task history full; remove completed tasks first") }
        let id = UUID().uuidString.lowercased()
        index.records.append(Record(id: id, prompt: prompt, state: "queued", output: "Queued", created: Date()))
        do { try save() } catch { index.records.removeLast(); throw error }
        runners[id] = runner
        schedule()
        return "Task created: \(id)\nBackground investigation; no system changes execute.\nWatch: /watch \(id)\nCancel: /cancel \(id)"
    }
    public func limit(_ value: Int? = nil) throws -> String {
        try load()
        if let value {
            guard (1...48).contains(value) else { throw AIError.message("Concurrency must be 1–48") }
            let old = index.concurrency; index.concurrency = value
            do { try save() } catch { index.concurrency = old; throw error }
            schedule()
        }
        return "Background AI concurrency: \(index.concurrency)/48; active \(running.count). Provider quotas still apply."
    }
    public func list() throws -> String {
        try load()
        return try limit() + "\n" + (index.records.isEmpty ? "No AI tasks. Use /task <request>." : index.records.reversed().map {
            "\($0.id)  \($0.state)  \($0.prompt.prefix(100).replacingOccurrences(of: "\n", with: " "))"
        }.joined(separator: "\n"))
    }
    public func show(_ id: String) throws -> String {
        try load()
        guard let record = index.records.first(where: { $0.id == id }) else { throw AIError.message("Unknown task") }
        return "Task \(id) [\(record.state)]\nRequest: \(record.prompt)\n\n\(record.output)"
    }
    public func cancel(_ id: String) throws -> String {
        try load()
        guard let i = index.records.firstIndex(where: { $0.id == id }), ["queued", "running"].contains(index.records[i].state) else { throw AIError.message("No active task with that ID") }
        let old = index.records[i]; index.records[i].state = "cancelled"
        do { try save() } catch { index.records[i] = old; throw error }
        running[id]?.cancel(); runners.removeValue(forKey: id)
        notify(id, finish: true); schedule()
        return "Task cancelled: " + id
    }
    public func remove(_ id: String) throws -> String {
        try load()
        guard let i = index.records.firstIndex(where: { $0.id == id }), !["queued", "running"].contains(index.records[i].state) else { throw AIError.message("Only finished tasks can be removed") }
        let old = index.records.remove(at: i)
        do { try save() } catch { index.records.insert(old, at: i); throw error }
        return "Task removed: " + id
    }
    public func watch(_ id: String) throws -> AsyncStream<String> {
        let initial = try show(id)
        let pair = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.yield(initial)
        if let record = index.records.first(where: { $0.id == id }), ["queued", "running"].contains(record.state) {
            let token = UUID(); watchers[id, default: [:]][token] = pair.continuation
            pair.continuation.onTermination = { [weak self] _ in Task { await self?.unwatch(id, token) } }
        } else { pair.continuation.finish() }
        return pair.stream
    }
    private func unwatch(_ id: String, _ token: UUID) { watchers[id]?.removeValue(forKey: token) }
    private func notify(_ id: String, finish: Bool = false) {
        guard let output = try? show(id) else { return }
        for continuation in watchers[id]?.values ?? [:].values {
            continuation.yield(output); if finish { continuation.finish() }
        }
        if finish { watchers.removeValue(forKey: id) }
    }
    private func update(_ id: String, _ event: AIProgress) {
        guard let i = index.records.firstIndex(where: { $0.id == id }), index.records[i].state == "running" else { return }
        switch event {
        case .answer(let text): index.records[i].output = String((index.records[i].output + text).suffix(24000))
        case .snapshot(let text): index.records[i].output = String(text.suffix(24000))
        case .reasoning: break // Live provider reasoning is transient, not stored in task history.
        case .status(let text): if index.records[i].output.isEmpty || index.records[i].output.hasPrefix("Activity: ") { index.records[i].output = "Activity: " + text + "\n" }
        }
        notify(id)
    }
    private func schedule() {
        for record in index.records where record.state == "queued" && running.count < index.concurrency {
            guard let runner = runners.removeValue(forKey: record.id), let i = index.records.firstIndex(where: { $0.id == record.id }) else { continue }
            index.records[i].state = "running"; index.records[i].output = ""
            do { try save() } catch { index.records[i].state = "queued"; runners[record.id] = runner; return }
            let id = record.id
            running[id] = Task {
                let pair = AsyncStream<AIProgress>.makeStream()
                let relay = Task { for await event in pair.stream { self.update(id, event) } }
                do {
                    try Task.checkCancellation()
                    let output = try await runner(id, record.prompt) { pair.continuation.yield($0) }
                    pair.continuation.finish(); await relay.value
                    self.finish(id, output: output, failed: false)
                } catch {
                    pair.continuation.finish(); await relay.value
                    self.finish(id, output: "Task failed or cancelled; inspect current state. No system changes executed.", failed: true)
                }
            }
        }
    }
    private func finish(_ id: String, output: String, failed: Bool) {
        running.removeValue(forKey: id)
        if let i = index.records.firstIndex(where: { $0.id == id }), index.records[i].state != "cancelled" {
            index.records[i].state = failed ? "failed" : "completed"; index.records[i].output = String(output.prefix(24000))
            do { try save() } catch { index.records[i].state = "unconfirmed"; index.records[i].output = "Could not persist task outcome." }
        }
        notify(id, finish: true); schedule()
    }
}
