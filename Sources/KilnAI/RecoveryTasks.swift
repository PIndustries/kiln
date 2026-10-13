import Foundation
import KilnKit

/// A bounded controller workflow. The model can request investigation, but cannot
/// approve, execute, or supply the evidence used to decide whether recovery worked.
public actor AIRecoveryTasks {
    public struct Owner: Codable, Sendable, Equatable {
        public let name: String
        public let publicKey: String
        public init(name: String, publicKey: String) { self.name = name; self.publicKey = publicKey }
    }
    public enum State: String, Codable, Sendable {
        case inspecting, awaitingApproval, executing, verifying, healthy, recovered
        case interrupted, needsReview, failed, denied, expired, closed
    }
    public struct Record: Codable, Sendable {
        public let id: String
        public let owner: Owner
        public let module: String
        public let created: Date
        public var state: State
        public var before: RecoveryEvidence?
        public var after: RecoveryEvidence?
        public var expires: Date?
        public var detail: String
    }
    public struct Controller: Sendable {
        public let authorize: @Sendable (String) throws -> Void
        public let inspect: @Sendable (String) async throws -> RecoveryEvidence
        public let execute: @Sendable (String, String, String) async throws -> Void
        public let receipt: @Sendable (String) async throws -> RecoveryReceipt?
        public init(authorize: @escaping @Sendable (String) throws -> Void,
                    inspect: @escaping @Sendable (String) async throws -> RecoveryEvidence,
                    execute: @escaping @Sendable (String, String, String) async throws -> Void,
                    receipt: @escaping @Sendable (String) async throws -> RecoveryReceipt?) {
            self.authorize = authorize; self.inspect = inspect; self.execute = execute; self.receipt = receipt
        }
    }
    private struct Journal: Codable { var version = 1; var records: [Record] }
    private let file: URL
    private var records: [Record] = []
    private var loaded = false
    private var faulted = false
    private var workers: [String: Task<Void, Never>] = [:]
    public init(directory: URL) { file = directory.appendingPathComponent("ai-recovery.json") }
    private func load() throws {
        guard !faulted else { throw AIError.message("Recovery journal unavailable; restart and reconcile") }
        guard !loaded else { return }
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard data.count <= 2_097_152 else { throw AIError.message("Recovery journal exceeds its limit") }
            let journal = try JSONDecoder().decode(Journal.self, from: data)
            guard journal.version == 1 else { throw AIError.message("Unsupported recovery journal version") }
            records = journal.records
            guard records.count <= 100, Set(records.map(\.id)).count == records.count,
                  records.allSatisfy({ UUID(uuidString: $0.id) != nil }) else { throw AIError.message("Invalid recovery journal") }
            for i in records.indices {
                switch records[i].state {
                case .inspecting:
                    records[i].state = .interrupted
                    records[i].detail = "Investigation interrupted. Reconcile to inspect again."
                case .executing, .verifying:
                    records[i].state = .needsReview
                    records[i].detail = "Runtime restarted. Reconcile the operation receipt and health; no mutation is automatically replayed."
                default: break
                }
            }
            try save()
        }
        loaded = true
    }
    private func expire() throws {
        var changed = false
        for i in records.indices where records[i].state == .awaitingApproval && (records[i].expires ?? .distantPast) <= Date() {
            records[i].state = .expired
            records[i].detail = "Approval expired. Start a new recovery task for fresh evidence and a new approval ID."
            changed = true
        }
        if changed { try save() }
    }
    private func save() throws {
        guard !faulted else { throw AIError.message("Recovery journal requires reconciliation") }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(Journal(records: records))
            guard data.count <= 2_097_152 else { throw AIError.message("Recovery journal exceeds its limit") }
            try KilnStateFile.write(data, to: file)
        } catch { faulted = true; throw error }
    }
    private func index(_ id: String, owner: Owner) throws -> Int {
        try load()
        guard let i = records.firstIndex(where: { $0.id == id && $0.owner == owner }) else {
            throw AIError.message("Unknown recovery task for this identity")
        }
        return i
    }
    public func record(_ id: String, owner: Owner) throws -> Record { let i = try index(id, owner: owner); return records[i] }
    public func inventory(owner: Owner) throws -> [Record] {
        try load(); try expire()
        return records.filter { $0.owner == owner }.reversed()
    }
    public func submit(module: String, owner: Owner, controller: Controller) throws -> String {
        try load(); try expire(); try controller.authorize(module)
        guard module.utf8.count <= 256, !module.isEmpty else { throw AIError.message("Invalid module identity") }
        // One active recovery per module, including requests from other identities.
        guard !records.contains(where: { $0.module == module && [.inspecting, .awaitingApproval, .executing, .verifying, .needsReview].contains($0.state) }) else {
            throw AIError.message("This module already has an active recovery; inspect tasks before requesting another")
        }
        guard records.count < 100, workers.count < 4 else { throw AIError.message("Recovery capacity reached; inspect or remove finished tasks") }
        let id = UUID().uuidString.lowercased()
        records.append(Record(id: id, owner: owner, module: module, created: Date(), state: .inspecting, detail: "Inspecting process state and configured health endpoint."))
        try save()
        workers[id] = Task { await self.investigate(id, controller: controller) }
        return "Recovery task created: recovery:\(id). Investigation runs independently of this connection; no change executes without approval."
    }
    private func change(_ id: String, _ body: (inout Record) -> Void) throws {
        guard !faulted, let i = records.firstIndex(where: { $0.id == id }) else { throw AIError.message("Recovery task unavailable") }
        body(&records[i]); try save()
    }
    private func investigate(_ id: String, controller: Controller) async {
        defer { workers.removeValue(forKey: id) }
        guard let r = records.first(where: { $0.id == id }) else { return }
        do {
            try controller.authorize(r.module)
            let evidence = try await controller.inspect(r.module)
            try controller.authorize(r.module)
            guard evidence.module == r.module else { throw AIError.message("Mismatched controller evidence") }
            try change(id) {
                $0.before = evidence
                switch evidence.health {
                case .healthy:
                    $0.state = .healthy; $0.detail = "Configured health endpoint returned HTTP 200. No recovery operation needed."
                case .unconfigured:
                    $0.state = .needsReview; $0.detail = "No health endpoint configured. Recovery cannot be verified; no operation proposed."
                case .unhealthy:
                    $0.state = .awaitingApproval; $0.expires = Date().addingTimeInterval(300)
                    $0.detail = "Health check failed or process is stopped. Propose restart of this exact generation. Restart can interrupt traffic and existing connections."
                }
            }
        } catch {
            try? change(id) { $0.state = .failed; $0.detail = "Inspection unavailable or permission revoked. No operation executed." }
        }
    }
    public func approve(_ id: String, owner: Owner, controller: Controller, now: Date = Date()) throws -> String {
        let r = try record(id, owner: owner)
        try controller.authorize(r.module)
        guard r.state == .awaitingApproval else { return "Recovery \(id): \(r.state.rawValue). No additional operation scheduled." }
        guard let expires = r.expires, expires > now else {
            try change(id) { $0.state = .expired; $0.detail = "Approval expired. Start a new recovery task for a new approval ID." }
            throw AIError.message("Recovery approval expired")
        }
        guard let before = r.before, workers.count < 4 else { throw AIError.message("Recovery worker unavailable") }
        // Commit consumption before launching any asynchronous side effect.
        try change(id) { $0.state = .executing; $0.detail = "Approval consumed. Executing one restart; outcome not yet verified." }
        workers[id] = Task {
            defer { self.workers.removeValue(forKey: id) }
            do {
                try controller.authorize(r.module)
                try await controller.execute(id, r.module, before.generation)
                try self.change(id) { $0.state = .verifying; $0.detail = "Operation returned. Verifying the receipt and configured health endpoint." }
                try await self.verify(id, controller: controller)
            } catch {
                try? self.change(id) { $0.state = .needsReview; $0.detail = "Execution or verification is unconfirmed. Reconcile before any new operation; this approval cannot execute again." }
            }
        }
        return "Recovery approval accepted. Follow recovery:\(id) in Tasks; success requires a recorded operation and a healthy replacement."
    }
    private func verify(_ id: String, controller: Controller) async throws {
        guard let r = records.first(where: { $0.id == id }) else { throw AIError.message("Unknown task") }
        try controller.authorize(r.module)
        let receipt = try await controller.receipt(id)
        var evidence = try await controller.inspect(r.module)
        // Allow a bounded startup window; all retries are read-only.
        for _ in 0..<9 where evidence.health == .unhealthy {
            try await Task.sleep(for: .milliseconds(500))
            try controller.authorize(r.module)
            evidence = try await controller.inspect(r.module)
        }
        try controller.authorize(r.module)
        let verified = receipt?.state == "succeeded" && receipt?.generation == evidence.generation && evidence.module == r.module && evidence.health == .healthy && evidence.processState == "running"
        try change(id) {
            $0.after = evidence; $0.state = verified ? .recovered : .needsReview
            $0.detail = verified ? "Recorded restart succeeded; the same replacement generation is running and its configured endpoint returned HTTP 200." : "Current state recorded, but receipt, generation and health do not establish recovery. No operation replayed."
        }
    }
    public func reconcile(_ id: String, owner: Owner, controller: Controller) throws -> String {
        let r = try record(id, owner: owner)
        try controller.authorize(r.module)
        guard workers[id] == nil, workers.count < 4 else { throw AIError.message("Recovery is still active or at capacity") }
        if [.interrupted, .failed].contains(r.state) {
            try change(id) { $0.state = .inspecting; $0.expires = nil }
            workers[id] = Task { await self.investigate(id, controller: controller) }
        } else if r.state == .needsReview {
            try change(id) { $0.state = .verifying }
            workers[id] = Task {
                defer { self.workers.removeValue(forKey: id) }
                do { try await self.verify(id, controller: controller) }
                catch { try? self.change(id) { $0.state = .needsReview; $0.detail = "Reconciliation unavailable. No operation replayed." } }
            }
        } else { return "Recovery \(id): \(r.state.rawValue). No reconciliation scheduled." }
        return "Read-only reconciliation started for recovery:" + id
    }
    public func deny(_ id: String, owner: Owner) throws -> String {
        let r = try record(id, owner: owner)
        guard r.state == .awaitingApproval else { throw AIError.message("Only a pending recovery proposal can be declined") }
        try change(id) { $0.state = .denied; $0.detail = "Proposal declined. No operation executed." }
        return "Recovery proposal declined."
    }
    public func close(_ id: String, owner: Owner) throws -> String {
        let r = try record(id, owner: owner)
        guard workers[id] == nil, r.state == .needsReview else { throw AIError.message("Only an inactive unconfirmed task can be closed") }
        try change(id) { $0.state = .closed; $0.detail = "Operator closed this unconfirmed recovery. This is not proof of recovery; its operation receipt is retained." }
        return "Unconfirmed recovery closed without replaying an operation."
    }
    public func remove(_ id: String, owner: Owner) throws -> String {
        let i = try index(id, owner: owner)
        guard workers[id] == nil, [.healthy, .recovered, .denied, .expired, .failed, .interrupted, .closed].contains(records[i].state) else {
            throw AIError.message("Cannot remove pending or unconfirmed recovery work")
        }
        records.remove(at: i); try save()
        return "Recovery task removed. Operation receipt retained."
    }
    public func show(_ id: String, owner: Owner) throws -> String {
        let r = try record(id, owner: owner)
        var lines = ["Recovery \(r.id) [\(r.state.rawValue)]", "Module: \(r.module)", r.detail]
        for (label, e) in [("Before", r.before), ("After", r.after)] {
            if let e { lines.append("\(label) [\(e.sampledAt.ISO8601Format())]: \(e.processState), health \(e.health.rawValue), generation \(e.generation)") }
        }
        if r.state == .needsReview || r.state == .interrupted { lines.append("Read-only reconcile: ai recovery reconcile recovery:" + id) }
        return lines.joined(separator: "\n")
    }
}
