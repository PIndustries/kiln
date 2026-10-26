import Foundation
import KilnKit

/// Workers belong to the runtime and identity, not the SSH observer. Disconnecting
/// detaches the observer; cancellation is explicit. Restart never replays a write.
public actor AIWorkSessions {
    public typealias Runner = @Sendable (String, @escaping @Sendable (AIProgress) -> Void) async throws -> String
    private struct Record: Codable { let owner: String; let session: String; var view: AIWorkSnapshot; var inbox: [String] = [] }
    private let directory: URL
    private var records: [String:Record] = [:]
    private var runners: [String:Runner] = [:]
    private var running: [String:Task<Void,Never>] = [:]
    private var observers: [String:[UUID:AsyncStream<AIWorkSnapshot>.Continuation]] = [:]
    private var loaded = false
    private var uncertain = false
    public init(directory: URL) { self.directory = directory }
    private func load() throws {
        guard !uncertain else { throw AIError.message("Worker state requires restart reconciliation") }
        guard !loaded else { return }
        let file = directory.appendingPathComponent("ai-work.json")
        if FileManager.default.fileExists(atPath:file.path) {
            let bytes = try Data(contentsOf:file)
            guard bytes.count <= 32_000_000 else { throw AIError.message("Worker history exceeds its storage guard") }
            records = try JSONDecoder().decode([String:Record].self,from:bytes)
            guard records.count <= 200 else { throw AIError.message("Worker history exceeds 200 records") }
            for id in records.keys where records[id]!.view.active {
                records[id]!.view.state = "interrupted"
                records[id]!.view.activity = "Runtime restarted; work was not replayed. Inspect source/history before retrying."
            }
        }
        loaded = true; try save()
    }
    private func save() throws {
        let bytes = try JSONEncoder().encode(records)
        guard bytes.count <= 32_000_000 else { throw AIError.message("Worker history full; remove completed work") }
        do { try KilnStateFile.write(bytes,to:directory.appendingPathComponent("ai-work.json")) }
        catch let error as KilnStateFile.CommitUncertain { uncertain = true; throw error }
    }
    public func start(owner: String, session: String, prompt: String, runner: @escaping Runner) throws -> String {
        try load()
        guard !prompt.isEmpty, prompt.utf8.count <= 8192 else { throw AIError.message("Worker prompt must be 1–8192 bytes") }
        guard records.count < 200 else { throw AIError.message("Worker history full; remove completed work") }
        guard !records.values.contains(where: { $0.owner == owner && $0.session == session && $0.view.active }) else { throw AIError.message("This chat already has active work. Send context or open another chat for a separate agent.") }
        let id = UUID().uuidString.lowercased()
        records[id] = Record(owner:owner,session:session,view:AIWorkSnapshot(id:id,prompt:prompt,state:"queued"))
        do { try save() } catch { records.removeValue(forKey:id); throw error }
        runners[id] = runner; schedule()
        return id
    }
    public func snapshot(_ id: String, owner: String) throws -> AIWorkSnapshot {
        try load()
        guard let record = records[id], record.owner == owner else { throw AIError.message("Unknown worker or access denied") }
        return record.view
    }
    public func list(owner: String) throws -> [AIWorkSnapshot] {
        try load(); return records.values.filter { $0.owner == owner }.map(\.view).sorted { $0.id < $1.id }
    }
    public func enqueue(_ text: String, id: String, owner: String) throws {
        _ = try snapshot(id,owner:owner)
        guard records[id]!.view.active, records[id]!.view.state != "cancelling" else { throw AIError.message("Worker finished or is cancelling. Send a new message to start another turn.") }
        guard !text.isEmpty, text.utf8.count <= 8192, records[id]!.inbox.count < 16 else { throw AIError.message("Context inbox full or message exceeds 8192 bytes; wait for acknowledgement") }
        let old = records[id]!
        let context = records[id]!.view.contextMessages ?? []
        guard context.reduce(0,{ $0+$1.utf8.count })+text.utf8.count <= 131072 else { throw AIError.message("Worker context transcript reached its storage guard; finish this task before starting another") }
        records[id]!.view.contextMessages = context+[text]
        records[id]!.inbox.append(text); records[id]!.view.queuedContext = records[id]!.inbox.count
        do { try save() } catch { records[id] = old; throw error }
        notify(id)
    }
    public func takeContext(_ id: String, owner: String) throws -> [String] {
        _ = try snapshot(id,owner:owner)
        let values = records[id]!.inbox
        guard !values.isEmpty else { return [] }
        let old = records[id]!
        records[id]!.inbox = []; records[id]!.view.queuedContext = 0
        do { try save() } catch { records[id] = old; throw error }
        notify(id); return values
    }
    public func cancel(_ id: String, owner: String) throws {
        _ = try snapshot(id,owner:owner)
        guard records[id]!.view.active else { return }
        let old = records[id]!
        records[id]!.view.state = running[id] == nil ? "cancelled" : "cancelling"
        records[id]!.view.activity = "Cancellation requested. Inspect source/history if publication had already started."
        do { try save() } catch { records[id] = old; throw error }
        running[id]?.cancel(); runners.removeValue(forKey:id); notify(id)
    }
    public func remove(_ id: String, owner: String) throws {
        let view = try snapshot(id,owner:owner)
        guard !view.active, running[id] == nil else { throw AIError.message("Only finished workers can be removed") }
        let old = records.removeValue(forKey:id)
        do { try save() } catch { records[id] = old; throw error }
    }
    public func watch(_ id: String, owner: String) throws -> AsyncStream<AIWorkSnapshot> {
        let view = try snapshot(id,owner:owner)
        let pair = AsyncStream<AIWorkSnapshot>.makeStream(bufferingPolicy:.bufferingNewest(1))
        pair.continuation.yield(view)
        if view.active {
            let token = UUID(); observers[id,default:[:]][token] = pair.continuation
            pair.continuation.onTermination = { [weak self] _ in Task { await self?.unwatch(id,token:token) } }
        } else { pair.continuation.finish() }
        return pair.stream
    }
    private func unwatch(_ id: String, token: UUID) { observers[id]?.removeValue(forKey:token) }
    private func notify(_ id: String) {
        guard let view = records[id]?.view else { return }
        for observer in observers[id]?.values ?? [:].values { observer.yield(view); if !view.active { observer.finish() } }
        if !view.active { observers.removeValue(forKey:id) }
    }
    private func update(_ id: String, _ value: AIWorkSnapshot) {
        guard records[id]?.view.state == "running" else { return }
        var value = value; value.queuedContext = records[id]!.inbox.count
        value.contextMessages = records[id]!.view.contextMessages
        records[id]!.view = value; notify(id)
    }
    private func schedule() {
        for id in records.keys.sorted() where records[id]!.view.state == "queued" && running.count < 48 {
            guard let runner = runners.removeValue(forKey:id) else { continue }
            records[id]!.view.state = "running"
            do { try save() } catch { records[id]!.view.state = "queued"; runners[id] = runner; return }
            let initial = records[id]!.view
            running[id] = Task {
                let relay = WorkProgressRelay(initial)
                let updates = Task { for await value in relay.stream { self.update(id,value) } }
                var output: String, failed = false
                do { try Task.checkCancellation(); output = try await runner(id) { relay.send($0) } }
                catch { output = "Work failed or was interrupted. Inspect source/history before retrying. " + String(describing:error); failed = true }
                relay.finish(); await updates.value
                self.finish(id,output:output,failed:failed)
            }
        }
    }
    private func finish(_ id: String, output: String, failed: Bool) {
        running.removeValue(forKey:id)
        if records[id] != nil {
            let cancelled = ["cancelling","cancelled"].contains(records[id]!.view.state)
            records[id]!.view.state = cancelled ? "cancelled" : failed ? "failed" : "completed"
            records[id]!.view.answer = String(output.prefix(24000))
            if !records[id]!.inbox.isEmpty { records[id]!.view.activity = "Finished before queued context was consumed; send it as a new turn." }
            do { try save() } catch { records[id]!.view.state = "unconfirmed"; records[id]!.view.activity = "Worker result checkpoint uncertain; inspect source/history." }
        }
        notify(id); schedule()
    }
}

/// Complete snapshots coalesce progress without dropping text deltas or starting
/// one asynchronous actor task per provider token.
private final class WorkProgressRelay: @unchecked Sendable {
    let stream: AsyncStream<AIWorkSnapshot>
    private let continuation: AsyncStream<AIWorkSnapshot>.Continuation
    private let lock = NSLock()
    private var view: AIWorkSnapshot
    init(_ view: AIWorkSnapshot) {
        self.view = view
        let pair = AsyncStream<AIWorkSnapshot>.makeStream(bufferingPolicy:.bufferingNewest(1))
        stream = pair.stream; continuation = pair.continuation
    }
    func send(_ event: AIProgress) {
        lock.withLock {
            switch event {
            case .answer(let text): view.answer = String((view.answer+text).suffix(24000))
            case .reasoning(let text): view.reasoning += text.prefix(max(0,131072-view.reasoning.count))
            case .snapshot(let text): view.answer = String(text.suffix(24000))
            case .status(let text):
                view.activity = String(text.prefix(1024))
                if text.hasPrefix("New user context") { view.file = nil }
            case .provider(let provider): view.provider = provider
            case .source(let file): view.file = file
            case .work: return
            }
            continuation.yield(view)
        }
    }
    func finish() { lock.withLock { continuation.finish() } }
}
