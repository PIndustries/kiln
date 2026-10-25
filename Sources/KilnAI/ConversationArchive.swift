import Foundation
import Crypto
import KilnKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class ConversationLease: @unchecked Sendable {
    private var fd: Int32?
    private let lock = NSLock()
    init(_ path: URL) throws {
        let descriptor = open(path.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw AIError.message("Conversation lock unavailable") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); throw AIError.message("Conversation is busy in another connection") }
        fd = descriptor
    }
    func release() {
        lock.withLock {
            if let fd { _ = flock(fd, LOCK_UN); close(fd); self.fd = nil }
        }
    }
    deinit { release() }
}

/// Private, bounded, explicitly opted-in checkpoints. Provider-visible thinking is transcript only; never restored as model context.
final class ConversationArchive: @unchecked Sendable {
    struct Record: Codable {
        var id = UUID().uuidString.lowercased()
        let slot: Int
        let owner: String
        let name: String
        var configuration: String
        var source: AIProviderSnapshot
        var context = AIConversationHistory()
        var contextEpoch = UUID().uuidString.lowercased()
        var events: [AIConversationEvent] = []
        var cursor: UInt64 = 0
        var retentionDays = 7
        var updated = Date()
        var expires = Date().addingTimeInterval(7 * 86400)
        var activeRun: String?
        mutating func event(_ kind: AIConversationEvent.Kind, _ text: String) {
            cursor += 1
            events.append(AIConversationEvent(cursor: cursor, kind: kind, text: String(text.prefix(24000)), source: kind == .answer || kind == .reasoning ? source : nil))
            events = Array(events.suffix(128)); updated = Date()
            expires = updated.addingTimeInterval(Double(retentionDays) * 86400)
            while events.count > 1, ((try? JSONEncoder().encode(self).count) ?? Int.max) > 1_048_576 { events.removeFirst() }
        }
        mutating func thinkingEvents(_ text: String) {
            var remaining = text[...]
            while !remaining.isEmpty {
                let chunk = remaining.prefix(24000)
                event(.reasoning, String(chunk)); remaining = remaining.dropFirst(chunk.count)
            }
        }
        func view(after: UInt64 = 0) -> AIConversationView {
            AIConversationView(name: name, id: id, events: events.filter { $0.cursor > after }, oldestCursor: events.first?.cursor ?? 0, latestCursor: cursor,
                gap: after > cursor || after < (events.first?.cursor ?? 1) - 1,
                notice: "Saved conversation \(name). Historical approval IDs are inactive after resume. Retention: \(retentionDays) days after activity.\(activeRun == nil ? "" : " A turn is in progress or was interrupted; it is never replayed.")", expiresAt: expires)
        }
    }
    struct Turn: Sendable { let id: String; let run: String; let lease: ConversationLease }
    struct Completion { let trimmed: Bool; let epoch: String; let history: AIConversationHistory }
    private struct Index: Codable { var schemaVersion = 1; var records: [Record] = [] }
    private let directory: URL
    private let lock = NSLock()
    private var uncertain = false
    private let writer: @Sendable (Data, URL) throws -> Void
    init(directory: URL, writer: @escaping @Sendable (Data, URL) throws -> Void = { try KilnStateFile.write($0, to: $1) }) {
        self.directory = directory.appendingPathComponent("ai-conversations"); self.writer = writer
    }
    static func fingerprint(_ config: AIConfiguration) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(config)).map { String(format: "%02x", $0) }.joined()
    }
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 32 && name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }
    private func lease(_ record: Record) throws -> ConversationLease { try ConversationLease(directory.appendingPathComponent("slot-\(record.slot).lock")) }
    private func persist(_ index: Index, to url: URL) throws {
        let bytes = try JSONEncoder().encode(index)
        guard bytes.count <= 16_777_216 else { throw AIError.message("Conversation archive is full; delete unused conversations") }
        do { try writer(bytes, url) }
        catch let error as KilnStateFile.CommitUncertain { uncertain = true; throw error }
    }
    private func transaction<T>(write: Bool = false, _ body: (inout Index) throws -> T) throws -> T {
        try lock.withLock {
            guard !uncertain else { throw AIError.message("Conversation save is uncertain; restart and reconcile before continuing") }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                var directoryInfo = stat()
                guard lstat(directory.path, &directoryInfo) == 0, directoryInfo.st_uid == geteuid(),
                      directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), directoryInfo.st_mode & 0o077 == 0 else { throw AIError.message("Conversation directory must be private and owned by the service user") }
                let fd = open(directory.appendingPathComponent("index.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
                guard fd >= 0 else { throw AIError.message("Conversation state unavailable") }
                defer { close(fd) }
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AIError.message("Conversation state is busy; retry after the current save") }
                defer { _ = flock(fd, LOCK_UN) }
                let url = directory.appendingPathComponent("index.json")
                var index = Index()
                if FileManager.default.fileExists(atPath: url.path) {
                    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard attrs[.type] as? FileAttributeType == .typeRegular, let size = attrs[.size] as? NSNumber,
                          size.intValue <= 16_777_216, (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { throw AIError.message("Conversation state is invalid or not private") }
                    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                    let bytes = try handle.read(upToCount: 16_777_217) ?? Data()
                    guard bytes.count <= 16_777_216 else { throw AIError.message("Conversation state exceeds its limit") }
                    index = try JSONDecoder().decode(Index.self, from: bytes)
                    guard index.schemaVersion == 1, index.records.count <= 32,
                          Set(index.records.map(\.slot)).count == index.records.count,
                          Set(index.records.map { $0.owner + ":" + $0.name }).count == index.records.count,
                          Set(index.records.map(\.id)).count == index.records.count else { throw AIError.message("Unsupported or invalid conversation state") }
                    for record in index.records {
                        guard (0..<32).contains(record.slot), UUID(uuidString: record.id) != nil, UUID(uuidString: record.contextEpoch) != nil, Self.validName(record.name),
                              record.owner.count == 64, record.owner.allSatisfy(\.isHexDigit), record.configuration.count == 64, record.configuration.allSatisfy(\.isHexDigit),
                              record.source == AIProviderSnapshot(provider: record.source.provider, profile: record.source.profile, model: record.source.model),
                              (1...30).contains(record.retentionDays), record.events.count <= 128, record.cursor < UInt64.max - 1024,
                              record.events.allSatisfy({ $0.cursor > 0 && $0.cursor <= record.cursor && $0.text.utf8.count <= 1_048_576 }),
                              record.events.allSatisfy({ event in event.source.map { $0 == AIProviderSnapshot(provider: $0.provider, profile: $0.profile, model: $0.model) } ?? true }),
                              zip(record.events, record.events.dropFirst()).allSatisfy({ $0.0.cursor < $0.1.cursor }),
                              record.context.messages.count <= 40, record.context.encodedBytes.map({ $0 <= 65536 }) == true,
                              record.context.messages.allSatisfy({ ["user", "assistant"].contains($0.role) && $0.tool_calls == nil && $0.providerItems == nil && $0.reasoning_content == nil }),
                              record.context.turnStarts == Array(Set(record.context.turnStarts)).sorted(),
                              record.context.turnStarts.allSatisfy({ record.context.messages.indices.contains($0) }),
                              record.context.turnStarts.allSatisfy({ record.context.messages[$0].role == "user" }),
                              (record.context.messages.isEmpty ? record.context.turnStarts.isEmpty : record.context.turnStarts.first == 0),
                              try JSONEncoder().encode(record).count <= 1_048_576 else { throw AIError.message("Invalid saved conversation") }
                    }
                }
                var pruned = false
                for i in index.records.indices.reversed() where index.records[i].expires <= Date() {
                    if let held = try? lease(index.records[i]) {
                        index.records.remove(at: i); pruned = true; withExtendedLifetime(held) {}
                    }
                }
                if pruned { try persist(index, to: url) }
                let value = try body(&index)
                if write { try persist(index, to: url) }
                return value
            } catch let error as AIError { throw error }
            catch { throw AIError.message("Saved conversation state unavailable or invalid; inspect storage and reconcile before retrying") }
        }
    }
    private func position(_ index: Index, owner: String, id: String) throws -> Int {
        guard let i = index.records.firstIndex(where: { $0.owner == owner && $0.id == id && $0.expires > Date() }) else { throw AIError.message("Conversation unavailable for this identity/scope or expired") }
        return i
    }
    func list(owner: String) throws -> String {
        try transaction { index in
            let records = index.records.filter { $0.owner == owner && $0.expires > Date() }.sorted { $0.updated > $1.updated }
            return records.isEmpty ? "No saved conversations for this identity and authorization scope." : records.map { "\($0.name) / \($0.source.displayName) / \($0.source.model) / cursor \($0.cursor) / retention \($0.retentionDays)d" }.joined(separator: "\n")
        }
    }
    func pruneExpired() throws { try transaction { _ in () } }
    func create(owner: String, name: String, config: AIConfiguration) throws -> Record {
        guard Self.validName(name) else { throw AIError.message("Conversation names use 1-32 lowercase letters, digits or dashes") }
        guard owner.count == 64, owner.allSatisfy(\.isHexDigit) else { throw AIError.message("Invalid conversation owner scope") }
        try config.validate()
        return try transaction(write: true) { index in
            guard !index.records.contains(where: { $0.owner == owner && $0.name == name }) else { throw AIError.message("Conversation already exists; use it or delete it explicitly") }
            guard index.records.count < 32, let slot = (0..<32).first(where: { slot in !index.records.contains(where: { $0.slot == slot }) }) else { throw AIError.message("Saved conversation limit reached (32); delete an unused conversation") }
            var record = Record(slot: slot, owner: owner, name: name, configuration: try Self.fingerprint(config), source: AIProviderSnapshot(provider: config.provider.rawValue, profile: config.profile, model: config.model))
            record.event(.notice, "Explicitly saved conversation. Prompts and answers are private files, not Vault-encrypted. Historic approval IDs are not restored as authority.")
            index.records.append(record); return record
        }
    }
    func lookup(owner: String, name: String) throws -> Record {
        try transaction { index in
            guard let record = index.records.first(where: { $0.owner == owner && $0.name == name && $0.expires > Date() }) else { throw AIError.message("Conversation unavailable for this identity/scope or expired") }
            return record
        }
    }
    func select(owner: String, name: String, config: AIConfiguration, reset: Bool) throws -> Record {
        try transaction(write: true) { index in
            guard let i = index.records.firstIndex(where: { $0.owner == owner && $0.name == name && $0.expires > Date() }) else { throw AIError.message("Conversation unavailable for this identity/scope or expired") }
            var record = index.records[i]
            let fingerprint = try Self.fingerprint(config)
            if record.configuration != fingerprint && !reset { throw AIError.message("Saved conversation has a different provider/configuration. Inspect its transcript or use --new-context explicitly") }
            if reset {
                let held = try lease(record); defer { withExtendedLifetime(held) {} }
                record.context = AIConversationHistory(); record.contextEpoch = UUID().uuidString.lowercased(); record.activeRun = nil; record.configuration = fingerprint
                record.source = AIProviderSnapshot(provider: config.provider.rawValue, profile: config.profile, model: config.model)
                record.event(.notice, "Provider context explicitly reset. Earlier transcript retained; old interactive approvals are inactive.")
            }
            index.records[i] = record; return record
        }
    }
    func begin(owner: String, id: String, config: AIConfiguration, prompt: String) throws -> (Record, Turn) {
        try transaction(write: true) { index in
            let i = try position(index, owner: owner, id: id)
            var record = index.records[i]
            guard record.configuration == (try Self.fingerprint(config)) else { throw AIError.message("Provider changed; select this conversation again with --new-context") }
            let held = try lease(record)
            if record.activeRun != nil { record.event(.notice, "Previous turn interrupted; no request or mutation was replayed.") }
            let run = UUID().uuidString.lowercased(); record.activeRun = run
            record.event(.request, prompt); index.records[i] = record
            return (record, Turn(id: id, run: run, lease: held))
        }
    }
    func complete(owner: String, turn: Turn, prompt: String, answer: String, thinking: String = "") throws -> Completion {
        try transaction(write: true) { index in
            let i = try position(index, owner: owner, id: turn.id)
            guard index.records[i].activeRun == turn.run else { throw AIError.message("Conversation turn changed; result not saved") }
            index.records[i].context = index.records[i].context.recording(index.records[i].context.messages + [AIMessage(role: "user", content: prompt), AIMessage(role: "assistant", content: answer)])
            let trimmed = index.records[i].context.trim(); index.records[i].activeRun = nil
            if trimmed { index.records[i].contextEpoch = UUID().uuidString.lowercased() }
            index.records[i].thinkingEvents(thinking)
            index.records[i].event(.answer, answer)
            if trimmed { index.records[i].event(.notice, "Provider context trimmed to recent complete turns; retained transcript is separate from model context.") }
            return Completion(trimmed: trimmed, epoch: index.records[i].contextEpoch, history: index.records[i].context)
        }
    }
    func interrupt(owner: String, turn: Turn, thinking: String = "") {
        try? transaction(write: true) { index in
            let i = try position(index, owner: owner, id: turn.id)
            guard index.records[i].activeRun == turn.run else { return }
            index.records[i].thinkingEvents(thinking)
            index.records[i].activeRun = nil; index.records[i].event(.notice, "Turn interrupted or failed; it was not automatically replayed.")
        }
    }
    func reset(owner: String, id: String) throws {
        try transaction(write: true) { index in
            let i = try position(index, owner: owner, id: id)
            let held = try lease(index.records[i]); defer { withExtendedLifetime(held) {} }
            index.records[i].context = AIConversationHistory(); index.records[i].contextEpoch = UUID().uuidString.lowercased(); index.records[i].activeRun = nil
            index.records[i].event(.notice, "Provider context and interactive approvals cleared. Saved transcript retained.")
        }
    }
    func recordOperation(owner: String, id: String, result: String) throws -> AIConversationHistory {
        try transaction(write: true) { index in
            let i = try position(index, owner: owner, id: id)
            let held = try lease(index.records[i]); defer { withExtendedLifetime(held) {} }
            let message = AIMessage(role: "user", content: "Historical local controller receipt; verify current state before further operations: " + String(result.prefix(24000)))
            if index.records[i].context.messages.isEmpty { index.records[i].context = AIConversationHistory().recording([message]) }
            else { index.records[i].context.messages.append(message) }
            index.records[i].context.trim()
            index.records[i].event(.operation, result)
            return index.records[i].context
        }
    }
    func retention(owner: String, name: String, days: Int) throws {
        guard (1...30).contains(days) else { throw AIError.message("Retention must be 1-30 days") }
        try transaction(write: true) { index in
            guard let i = index.records.firstIndex(where: { $0.owner == owner && $0.name == name }) else { throw AIError.message("Conversation unavailable") }
            let held = try lease(index.records[i]); defer { withExtendedLifetime(held) {} }
            index.records[i].retentionDays = days
            index.records[i].event(.notice, "Retention changed to \(days) days after activity.")
        }
    }
    func delete(owner: String, name: String) throws {
        try transaction(write: true) { index in
            guard let i = index.records.firstIndex(where: { $0.owner == owner && $0.name == name }) else { throw AIError.message("Conversation unavailable") }
            let held = try lease(index.records[i]); defer { withExtendedLifetime(held) {} }
            index.records.remove(at: i)
        }
    }
}
