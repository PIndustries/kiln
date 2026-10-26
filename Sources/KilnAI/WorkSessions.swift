import Foundation
import KilnKit

/// Runtime-owned workers, with local immutable event batches. Restart reconstructs
/// evidence and marks interrupted work; it never invokes a runner or a tool.
public actor AIWorkSessions {
    public typealias Runner = @Sendable (String, @escaping @Sendable (AIProgress) -> Void) async throws -> String
    private struct Record: Codable {
        let owner: String; let session: String; var view: AIWorkSnapshot
        var inbox: [String] = []; var workspace: String?; var created: Date?; var inboxIDs: [String]?
    }
    private let directory: URL
    private var journal: WorkJournal<Record> { WorkJournal(directory:directory) }
    private var records: [String:Record] = [:], archived: [String:Record] = [:]
    private var runners: [String:Runner] = [:]
    private var running: [String:Task<Void,Never>] = [:]
    private var relays: [String:WorkProgressRelay] = [:]
    private var observers: [String:[UUID:AsyncStream<AIWorkSnapshot>.Continuation]] = [:]
    private var loaded = false
    private var failedJournals: Set<String> = []
    public init(directory: URL) { self.directory = directory }
    private func load() throws {
        guard !loaded else { return }
        var restored: [String:Record] = [:], removed: [String:Record] = [:]
        if let bytes = try journal.legacySnapshot() {
            restored = try JSONDecoder().decode([String:Record].self,from:bytes)
            guard restored.count <= 200 else { throw AIError.message("Worker legacy history exceeds 200 records") }
        }
        for id in try journal.ids() {
            var record: Record?
            for batch in try journal.batches(id) {
                if let checkpoint = batch.checkpoint { record = checkpoint }
                else {
                    guard record != nil else { throw AIError.message("Worker journal has no initial checkpoint") }
                    for event in batch.events { Self.apply(event,to:&record!.view) }
                }
                record?.view.eventSequence = batch.events.last!.sequence
            }
            if let record {
                guard record.view.id == id else { throw AIError.message("Worker journal checkpoint identity mismatch") }
                if record.view.state == "removed" { removed[id] = record; restored.removeValue(forKey:id) }
                else { restored[id] = record }
            }
        }
        guard restored.count <= 200 else { throw AIError.message("Worker history exceeds 200 records") }
        // Migrate old snapshots once, retaining the original file for recovery.
        for id in restored.keys.sorted() where restored[id]!.view.eventSequence == nil {
            restored[id]!.inboxIDs = restored[id]!.inbox.map { _ in UUID().uuidString.lowercased() }
            restored[id]!.view.eventSequence = 1
            try journal.append(id,after:0,events:[AIWorkEvent(.migrated,text:"Imported legacy snapshot; earlier intermediate events were not recorded")],checkpoint:restored[id]!)
        }
        records = restored; archived = removed; loaded = true
        for id in records.keys.sorted() where records[id]!.view.active {
            var record = records[id]!
            record.view.state = "interrupted"
            record.view.activity = "Runtime restarted; work was not replayed. Inspect source/history and unmatched tool starts before retrying."
            do { try commit(id,record:record,events:[AIWorkEvent(.interrupted,text:record.view.activity)]) }
            catch { loaded = false; throw error }
        }
    }
    private func commit(_ id: String, record: Record, events: [AIWorkEvent], checkpoint: Bool = true) throws {
        guard !failedJournals.contains(id) else { throw AIError.message("Worker event storage failed; inspect history before retrying") }
        let previous = records[id]?.view.eventSequence ?? 0
        var record = record; record.view.eventSequence = previous+events.count
        do { try journal.append(id,after:previous,events:events,checkpoint:checkpoint ? record : nil) }
        catch { storageFailed(id); throw error }
        records[id] = record
    }
    public func start(owner: String, session: String, prompt: String, workspace: String? = nil, runner: @escaping Runner) throws -> String {
        try load()
        guard !prompt.isEmpty, prompt.utf8.count <= 8192 else { throw AIError.message("Worker prompt must be 1–8192 bytes") }
        guard records.count < 200 else { throw AIError.message("Worker history full; remove completed work") }
        guard !records.values.contains(where: { $0.owner == owner && $0.session == session && $0.view.active }) else { throw AIError.message("This chat already has active work. Send context or open another chat for a separate agent.") }
        let id = UUID().uuidString.lowercased()
        let record = Record(owner:owner,session:session,view:AIWorkSnapshot(id:id,prompt:prompt,state:"queued"),workspace:workspace,created:Date(),inboxIDs:[])
        try commit(id,record:record,events:[AIWorkEvent(.created,text:prompt)])
        runners[id] = runner; schedule(); return id
    }
    public func active(owner: String, workspace: String) throws -> AIWorkSnapshot? {
        try load()
        return records.values.filter { $0.owner == owner && $0.workspace == workspace && $0.view.active }.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }.first?.view
    }
    public func snapshot(_ id: String, owner: String) throws -> AIWorkSnapshot {
        try load()
        guard let record = records[id], record.owner == owner else { throw AIError.message("Unknown worker or access denied") }
        return record.view
    }
    public func list(owner: String) throws -> [AIWorkSnapshot] {
        try load(); return records.values.filter { $0.owner == owner }.map(\.view).sorted { $0.id < $1.id }
    }
    public func events(_ id: String, owner: String, after: Int = 0, limit: Int = 100) throws -> [AIWorkEvent] {
        try load()
        guard let record = records[id] ?? archived[id], record.owner == owner else { throw AIError.message("Unknown worker or access denied") }
        guard after >= 0, (1...100).contains(limit) else { throw AIError.message("Use a nonnegative event cursor and 1–100 events per page") }
        var result: [AIWorkEvent] = [], bytes = 0
        for event in try journal.batches(id).flatMap(\.events) where event.sequence > after {
            let size = try JSONEncoder().encode(event).count
            if result.count == limit || (!result.isEmpty && bytes+size > 2_097_152) { break }
            result.append(event); bytes += size
        }
        return result
    }
    @discardableResult public func enqueue(_ text: String, id: String, owner: String) throws -> String {
        _ = try snapshot(id,owner:owner)
        guard records[id]!.view.active, records[id]!.view.state != "cancelling" else { throw AIError.message("Worker finished or is cancelling. Send a new message to start another turn.") }
        guard !text.isEmpty, text.utf8.count <= 8192, records[id]!.inbox.count < 16 else { throw AIError.message("Context inbox full or message exceeds 8192 bytes; wait for acknowledgement") }
        try flush(id)
        var record = records[id]!
        let context = record.view.contextMessages ?? []
        guard context.reduce(0,{ $0+$1.utf8.count })+text.utf8.count <= 131072 else { throw AIError.message("Worker context transcript reached its storage guard; finish this task before starting another") }
        let contextID = UUID().uuidString.lowercased()
        record.view.contextMessages = context+[text]; record.inbox.append(text)
        record.inboxIDs = (record.inboxIDs ?? [])+[contextID]; record.view.queuedContext = record.inbox.count
        try commit(id,record:record,events:[AIWorkEvent(.contextQueued,text:text,contextIDs:[contextID])]); notify(id)
        return contextID
    }
    public func takeContext(_ id: String, owner: String) throws -> [String] {
        _ = try snapshot(id,owner:owner); try flush(id)
        var record = records[id]!; let values = record.inbox
        guard !values.isEmpty else { return [] }
        let ids = record.inboxIDs ?? []
        record.inbox = []; record.inboxIDs = []; record.view.queuedContext = 0
        record.view.consumedContext = (record.view.consumedContext ?? 0)+values.count
        try commit(id,record:record,events:[AIWorkEvent(.contextConsumed,text:"Delivered at a safe step; this does not claim the requested change was applied",contextIDs:ids)])
        notify(id); return values
    }
    /// Tool boundaries await this durable write. A missing return after a start
    /// means unknown outcome, never permission to retry the operation.
    public func recordTool(_ event: AIWorkEvent, id: String, owner: String) throws {
        _ = try snapshot(id,owner:owner)
        guard event.kind == .toolStarted || event.kind == .toolReturned,
              records[id]!.view.state == "running" || (event.kind == .toolReturned && records[id]!.view.state == "cancelling") else { throw AIError.message("Worker cannot execute another tool in its current state") }
        try flush(id); try commit(id,record:records[id]!,events:[event],checkpoint:false); notify(id)
    }
    public func cancel(_ id: String, owner: String) throws {
        _ = try snapshot(id,owner:owner)
        guard records[id]!.view.active else { return }
        try flush(id); var record = records[id]!
        record.view.state = running[id] == nil ? "cancelled" : "cancelling"
        record.view.activity = "Cancellation requested. Inspect source/history if publication had already started."
        try commit(id,record:record,events:[AIWorkEvent(.cancellationRequested,text:record.view.activity)])
        running[id]?.cancel(); runners.removeValue(forKey:id); notify(id)
    }
    public func remove(_ id: String, owner: String) throws {
        let view = try snapshot(id,owner:owner)
        guard !view.active, running[id] == nil else { throw AIError.message("Only finished workers can be removed") }
        var record = records[id]!; record.view.state = "removed"
        try commit(id,record:record,events:[AIWorkEvent(.removed,text:"Removed from active history; evidence retained")])
        archived[id] = records.removeValue(forKey:id)
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
    private static func apply(_ event: AIWorkEvent, to view: inout AIWorkSnapshot) {
        switch event.kind {
        case .answer: view.answer = String((view.answer+(event.text ?? "")).suffix(24000))
        case .reasoning: view.reasoning += (event.text ?? "").prefix(max(0,131072-view.reasoning.count))
        case .snapshot: view.answer = String((event.text ?? "").suffix(24000))
        case .status:
            view.activity = String((event.text ?? "").prefix(1024))
            if view.activity.hasPrefix("New user context") { view.file = nil }
        case .source: view.file = event.file
        case .provider: view.provider = event.provider
        default: break
        }
    }
    private func flush(_ id: String) throws {
        guard let relay = relays[id] else { return }
        let events = try relay.take()
        guard !events.isEmpty, var record = records[id] else { return }
        for event in events { Self.apply(event,to:&record.view) }
        try commit(id,record:record,events:events,checkpoint:false)
        notify(id)
    }
    private func storageFailed(_ id: String) {
        failedJournals.insert(id); running[id]?.cancel(); runners.removeValue(forKey:id)
        records[id]?.view.state = "unconfirmed"
        records[id]?.view.activity = "Event storage failed; worker stopped. Inspect journal and source/release history before retrying."
        notify(id)
    }
    private func schedule() {
        for id in records.keys.sorted() where records[id]!.view.state == "queued" && running.count < 48 {
            guard let runner = runners.removeValue(forKey:id) else { continue }
            var record = records[id]!; record.view.state = "running"
            do { try commit(id,record:record,events:[AIWorkEvent(.running)]) }
            catch { storageFailed(id); continue }
            let relay = WorkProgressRelay(); relays[id] = relay
            running[id] = Task {
                let updates = Task {
                    for await _ in relay.stream {
                        // Coalesce disk writes, preserving every raw event in the batch.
                        try? await Task.sleep(for:.milliseconds(100))
                        do { try self.flush(id) } catch { self.storageFailed(id); break }
                    }
                }
                var output: String, failed = false
                do { try Task.checkCancellation(); output = try await runner(id) { relay.send($0) } }
                catch { output = "Work failed or was interrupted. Inspect source/history before retrying. " + String(describing:error); failed = true }
                relay.finish(); await updates.value
                self.finish(id,output:output,failed:failed)
            }
        }
    }
    private func finish(_ id: String, output: String, failed: Bool) {
        defer { running.removeValue(forKey:id); relays.removeValue(forKey:id); notify(id); schedule() }
        guard !failedJournals.contains(id) else {
            records[id]?.view.answer = String(output.prefix(24000)); return
        }
        do {
            try flush(id)
            if var record = records[id] {
                let cancelled = ["cancelling","cancelled"].contains(record.view.state)
                record.view.state = cancelled ? "cancelled" : failed ? "failed" : "completed"
                record.view.answer = String(output.prefix(24000))
                if !record.inbox.isEmpty { record.view.activity = "Finished before queued context was consumed; send it as a new turn." }
                try commit(id,record:record,events:[AIWorkEvent(.finished,text:output)])
            }
        } catch { storageFailed(id) }
    }
}

/// UI snapshots may coalesce; the pending event list never drops text or tool
/// evidence. Exhausting this memory guard fails the worker explicitly.
private final class WorkProgressRelay: @unchecked Sendable {
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var pending: [AIWorkEvent] = []
    private var bytes = 0
    private var overflow = false
    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy:.bufferingNewest(1))
        stream = pair.stream; continuation = pair.continuation
    }
    func send(_ progress: AIProgress) {
        lock.withLock {
            var event: AIWorkEvent
            var size = 256
            switch progress {
            case .answer(let text): event = AIWorkEvent(.answer,text:text); size += text.utf8.count
            case .reasoning(let text): event = AIWorkEvent(.reasoning,text:text); size += text.utf8.count
            case .snapshot(let text): event = AIWorkEvent(.snapshot,text:text); size += text.utf8.count
            case .status(let text): event = AIWorkEvent(.status,text:text); size += text.utf8.count
            case .source(let file): event = AIWorkEvent(.source); event.file = file; size += file.source.utf8.count
            case .provider(let provider): event = AIWorkEvent(.provider); event.provider = provider
            case .work: return
            }
            guard !overflow, bytes+size <= 4_194_304 else { overflow = true; continuation.yield(()); return }
            pending.append(event); bytes += size; continuation.yield(())
        }
    }
    func take() throws -> [AIWorkEvent] {
        try lock.withLock {
            guard !overflow else { throw AIError.message("Worker event buffer full; work stopped without silently dropping evidence") }
            defer { pending = []; bytes = 0 }; return pending
        }
    }
    func finish() { lock.withLock { continuation.finish() } }
}
