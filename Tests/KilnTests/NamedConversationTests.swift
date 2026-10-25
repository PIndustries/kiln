import Foundation
import Testing
@testable import KilnKit
import KilnRuntime
import KilnTerminal
@testable import KilnAI
@testable import KilnCommands

private let savedOwner = String(repeating: "a", count: 64)
private let savedConfig = AIConfiguration(baseURL: "http://127.0.0.1:11434", model: "SavedModel-v1", secret: "", provider: .ollama, profile: "local")
private let savedKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
private func savedRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return root
}
private func savedAsk(_ ai: KilnAssistant, _ text: String, session: String = "first", config: AIConfiguration = savedConfig) async throws -> String {
    try await ai.ask(text, session: session, configuration: config, key: "", modules: [], context: "fixture", knowledge: nil) { _, _ in "unused" }
}

@Test func namedConversationRestoresCompletedContextAndTranscriptWithoutReasoningOrCredentials() async throws {
    let root = try savedRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let config = AIConfiguration(baseURL: "https://PRIVATE-ENDPOINT.invalid/v1", model: "CaseSensitiveModel", secret: "PRIVATE-CREDENTIAL-REFERENCE", provider: .erebine, profile: "private")
    let first = KilnAssistant(directory: root) { _, _, _, _ in
        var answer = AIMessage(role: "assistant", content: "Remembered PEBBLE")
        answer.reasoning_content = "PRIVATE_REASONING"; answer.providerItems = ["PRIVATE_OPAQUE_HISTORY"]
        return answer
    }
    _ = try await first.newConversation(owner: savedOwner, name: "work", session: "first", configuration: config)
    _ = try await savedAsk(first, "Remember PEBBLE", config: config)
    let restored = KilnAssistant(directory: root) { _, _, messages, _ in
        #expect(messages.contains { $0.content == "Remember PEBBLE" })
        #expect(messages.contains { $0.content == "Remembered PEBBLE" })
        #expect(messages.allSatisfy { $0.reasoning_content == nil && $0.providerItems == nil })
        return AIMessage(role: "assistant", content: "Continuing PEBBLE")
    }
    let view = try await restored.useConversation(owner: savedOwner, name: "work", session: "second", configuration: config)
    #expect(view.events.contains { $0.kind == .answer && $0.source?.model == "CaseSensitiveModel" })
    _ = try await savedAsk(restored, "Continue", session: "second", config: config)
    #expect(await restored.contextStatus("second").contains("saved conversation work"))
    let file = root.appendingPathComponent("ai-conversations/index.json")
    let bytes = try String(contentsOf: file, encoding: .utf8)
    for value in ["PRIVATE_REASONING", "PRIVATE_OPAQUE_HISTORY", "PRIVATE-CREDENTIAL-REFERENCE", "PRIVATE-ENDPOINT"] { #expect(!bytes.contains(value)) }
    #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect((try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
}

@Test func savedConversationRequiresExplicitRebindingBeforeSendingContextToAnotherProfile() async throws {
    let root = try savedRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let ai = KilnAssistant(directory: root) { _, _, _, _ in AIMessage(role: "assistant", content: "old private answer") }
    _ = try await ai.newConversation(owner: savedOwner, name: "work", session: "first", configuration: savedConfig)
    _ = try await savedAsk(ai, "old private prompt")
    let changed = savedConfig.freshContext()
    do { _ = try await ai.useConversation(owner: savedOwner, name: "work", session: "new", configuration: changed); Issue.record("Silently rebound context") } catch {}
    let second = KilnAssistant(directory: root) { _, _, messages, _ in
        #expect(!messages.contains { $0.content == "old private prompt" })
        return AIMessage(role: "assistant", content: "fresh")
    }
    let view = try await second.useConversation(owner: savedOwner, name: "work", session: "new", configuration: changed, reset: true)
    #expect(view.events.contains { $0.text == "old private answer" })
    _ = try await savedAsk(second, "new prompt", session: "new", config: changed)
}

private actor SavedGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@Test func savedConversationRejectsConcurrentWritersAndDeletionWhileTurnRuns() async throws {
    let root = try savedRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let gate = SavedGate()
    let first = KilnAssistant(directory: root) { _, _, _, _ in await gate.wait(); return AIMessage(role: "assistant", content: "done") }
    _ = try await first.newConversation(owner: savedOwner, name: "work", session: "first", configuration: savedConfig)
    let worker = Task { try await savedAsk(first, "slow") }
    defer { Task { await gate.release() } }
    for _ in 0..<200 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(await gate.entered)
    let second = KilnAssistant(directory: root) { _, _, _, _ in Issue.record("Concurrent inference started"); return AIMessage(role: "assistant", content: "wrong") }
    _ = try await second.useConversation(owner: savedOwner, name: "work", session: "second", configuration: savedConfig)
    do { _ = try await savedAsk(second, "concurrent", session: "second"); Issue.record("Concurrent writer admitted") } catch {}
    do { _ = try await second.deleteConversation(owner: savedOwner, name: "work", session: "second"); Issue.record("Deleted active conversation") } catch {}
    await gate.release(); _ = try await worker.value
    _ = try await second.deleteConversation(owner: savedOwner, name: "work", session: "second")
    #expect(try await second.savedConversations(owner: savedOwner).contains("No saved conversations"))
}

@Test func interruptedSavedRequestIsNotReplayedAndHasNoProviderContext() async throws {
    let root = try savedRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let archive = ConversationArchive(directory: root)
    let record = try archive.create(owner: savedOwner, name: "work", config: savedConfig)
    do { _ = try archive.begin(owner: savedOwner, id: record.id, config: savedConfig, prompt: "NEVER_REPLAY_OLD_REQUEST") }
    let recovered = KilnAssistant(directory: root) { _, _, messages, _ in
        #expect(!messages.contains { $0.content == "NEVER_REPLAY_OLD_REQUEST" })
        return AIMessage(role: "assistant", content: "new answer")
    }
    let view = try await recovered.useConversation(owner: savedOwner, name: "work", session: "new", configuration: savedConfig)
    #expect(view.events.contains { $0.text == "NEVER_REPLAY_OLD_REQUEST" })
    _ = try await savedAsk(recovered, "explicit new request", session: "new")
    let events = try await recovered.conversationEvents(owner: savedOwner, name: "work")
    #expect(events.events.contains { $0.kind == .notice && $0.text.contains("Previous turn interrupted") })
}

@Test func conversationScopeBindsIdentityKeyRoleAndModuleGrants() async throws {
    let root = try savedRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try KilnRuntime(stateDirectory: root)
    let assistant = KilnAssistant(directory: root) { _, _, _, _ in AIMessage(role: "assistant", content: "scoped private answer") }
    let commands = KilnCommands(runtime: runtime, assistant: assistant)
    try commands.bootstrapIdentity(username: "admin", keys: [savedKey])
    _ = try commands.identities.set(name: "user", role: "operator", key: savedKey, modules: ["a/worker"])
    _ = try commands.identities.set(name: "other", role: "operator", key: savedKey, modules: ["a/worker"])
    try KilnStateFile.write(JSONEncoder().encode(savedConfig), to: root.appendingPathComponent("ai.json"))
    let user = commands.forIdentity(name: "user", publicKey: savedKey)
    #expect(await user.execute("ai conversation new work", sessionID: "first").status == 0)
    #expect(await user.execute("ai ask private", sessionID: "first").status == 0)
    #expect(await user.execute("ai conversation use work", sessionID: "new").conversation?.events.contains { $0.text == "scoped private answer" } == true)
    #expect(await commands.forIdentity(name: "other", publicKey: savedKey).execute("ai conversation use work").status != 0)
    _ = try commands.identities.set(name: "user", role: "operator", key: nil, modules: ["b/worker"])
    #expect(await user.execute("ai conversation list").text.contains("No saved conversations"))
    #expect(await user.execute("ai conversation use work").status != 0)
    #expect(await user.execute("ai context", sessionID: "first").text.contains("Completed turns: 0"))
    _ = try commands.identities.set(name: "user", role: "viewer", key: nil, modules: [], revoke: true)
    #expect(await user.execute("ai conversation list").status != 0)
    await runtime.shutdown()
}

@Test func savedEventCursorsSignalRetentionGapsAndDoNotRepeatAlreadyReadEvents() throws {
    var record = ConversationArchive.Record(slot: 0, owner: savedOwner, name: "test", configuration: try ConversationArchive.fingerprint(savedConfig), source: AIProviderSnapshot(provider: "ollama", profile: "local"))
    for i in 0..<150 { record.event(.notice, "event \(i)") }
    #expect(record.events.count == 128 && record.view().gap)
    let cursor = record.events[100].cursor
    let page = record.view(after: cursor)
    #expect(!page.gap && page.events.count == 27 && page.events.allSatisfy { $0.cursor > cursor })
    #expect(record.view(after: 999).gap)
}

@Test func expiredConversationDataIsPrunedAndDeletionPreventsSlotReuseFromRevivingOldIDs() throws {
    let root = try savedRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let archive = ConversationArchive(directory: root)
    var record = try archive.create(owner: savedOwner, name: "expired", config: savedConfig)
    record.event(.request, "PRIVATE_EXPIRED_PROMPT"); record.expires = Date().addingTimeInterval(-1)
    let file = root.appendingPathComponent("ai-conversations/index.json")
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
    try KilnStateFile.write(JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "records": [encoded]]), to: file)
    #expect(try archive.list(owner: savedOwner).contains("No saved conversations"))
    #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("PRIVATE_EXPIRED_PROMPT"))
    let replacement = try archive.create(owner: savedOwner, name: "new", config: savedConfig)
    #expect(replacement.slot == record.slot && replacement.id != record.id)
    #expect(throws: (any Error).self) { try archive.begin(owner: savedOwner, id: record.id, config: savedConfig, prompt: "old") }
    try archive.delete(owner: savedOwner, name: "new")
    #expect(throws: (any Error).self) { try archive.lookup(owner: savedOwner, name: "new") }
}

private final class ArchiveFailure: @unchecked Sendable {
    private let lock = NSLock(); private var writes = 0
    let afterCommit: Bool
    let failAt: Int
    init(afterCommit: Bool, failAt: Int = 2) { self.afterCommit = afterCommit; self.failAt = failAt }
    func write(_ bytes: Data, to url: URL) throws {
        try lock.withLock {
            writes += 1
            if writes == failAt && !afterCommit { throw AIError.message("fixture write rejected") }
            try KilnStateFile.write(bytes, to: url)
            if writes == failAt { throw KilnStateFile.CommitUncertain() }
        }
    }
}
@Test func conversationWriteFailuresPreserveOldStateAndUncertainCommitsRequireReconciliation() throws {
    for after in [false, true] {
        let root = try savedRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let failure = ArchiveFailure(afterCommit: after)
        let archive = ConversationArchive(directory: root, writer: { try failure.write($0, to: $1) })
        let record = try archive.create(owner: savedOwner, name: "work", config: savedConfig)
        #expect(throws: (any Error).self) { try archive.reset(owner: savedOwner, id: record.id) }
        if after { #expect(throws: (any Error).self) { try archive.list(owner: savedOwner) } }
        else { #expect(try archive.lookup(owner: savedOwner, name: "work").cursor == 1) }
        let reopened = ConversationArchive(directory: root)
        #expect(try reopened.lookup(owner: savedOwner, name: "work").cursor == (after ? 2 : 1))
    }
}

@Test func corruptOrPublicConversationStateFailsClosedWithoutReflectingPrivateContent() throws {
    let root = try savedRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let archive = ConversationArchive(directory: root)
    _ = try archive.create(owner: savedOwner, name: "work", config: savedConfig)
    let file = root.appendingPathComponent("ai-conversations/index.json")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    #expect(throws: (any Error).self) { try archive.list(owner: savedOwner) }
    try KilnStateFile.write(Data("{\"schemaVersion\":2,\"records\":[],\"private\":\"PRIVATE_BAD_STATE\"}".utf8), to: file)
    do { _ = try archive.list(owner: savedOwner); Issue.record("Future schema accepted") }
    catch { #expect(!String(describing: error).contains("PRIVATE_BAD_STATE")) }
}

@Test func terminalRestoresSourceLabelsAndLocalConversationShortcuts() {
    var ui = KilnTerminal(); _ = ui.handle(.text("7"))
    let source = AIProviderSnapshot(provider: "erebine", profile: "work", model: "OriginalCase")
    ui.restoreConversation(AIConversationView(name: "saved", events: [AIConversationEvent(cursor: 1, kind: .request, text: "question"), AIConversationEvent(cursor: 2, kind: .answer, text: "historical answer", source: source)], notice: "Old approval IDs are inactive"))
    #expect(ui.render().contains("Saved: saved") && ui.render().contains("KILN / Erebine / work / OriginalCase"))
    _ = ui.handle(.text("/conversation use saved"))
    #expect(ui.handle(.enter) == [.command("ai conversation use saved")])
    ui.finish(text: "selected", status: 0)
    _ = ui.handle(.text("/conversations"))
    #expect(ui.handle(.enter) == [.command("ai conversation list")])
}

@Test func savedContextResetInvalidatesOtherConnectionsHistoricalApprovals() async throws {
    let root = try savedRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let ai = KilnAssistant(directory: root) { _, _, messages, _ in
        if messages.last?.role == "tool" { return AIMessage(role: "assistant", content: "Review the pending proposal") }
        let call = try JSONDecoder().decode(AIToolCall.self, from: Data("{\"id\":\"operation\",\"type\":\"function\",\"function\":{\"name\":\"request_operation\",\"arguments\":\"{\\\"module\\\":\\\"demo/worker\\\",\\\"operation\\\":\\\"stop\\\"}\"}}".utf8))
        return AIMessage(role: "assistant", content: nil, tool_calls: [call])
    }
    _ = try await ai.newConversation(owner: savedOwner, name: "work", session: "first", configuration: savedConfig)
    _ = try await ai.ask("propose stop", session: "first", configuration: savedConfig, key: "", modules: [ModuleSnapshot(application: "demo", name: "worker", version: "1", state: "running", pid: 123)], context: "fixture", knowledge: nil) { _, _ in "unused" }
    let proposal = try #require(await ai.pendingProposals(session: "first").first)
    let cold = KilnAssistant(directory: root)
    let view = try await cold.useConversation(owner: savedOwner, name: "work", session: "second", configuration: savedConfig)
    #expect(view.events.contains { $0.kind == .answer && $0.text.contains(proposal.id) })
    do { _ = try await cold.takeApproval(proposal.id, session: "second"); Issue.record("Historical approval restored") } catch {}
    _ = try await cold.reset("second")
    #expect(await ai.pendingProposals(session: "first").isEmpty)
    do { _ = try await ai.takeApproval(proposal.id, session: "first"); Issue.record("Approval survived another connection's reset") } catch {}
}

@Test func savedContextStaysWithinWholeTurnLimitsAndOperationReceiptsSurviveResume() async throws {
    let root = try savedRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let ai = KilnAssistant(directory: root) { _, _, _, _ in AIMessage(role: "assistant", content: "answer") }
    _ = try await ai.newConversation(owner: savedOwner, name: "work", session: "first", configuration: savedConfig)
    for i in 0..<22 { _ = try await savedAsk(ai, "turn \(i)") }
    #expect(await ai.contextStatus("first").contains("Completed turns: 20"))
    let warning = await ai.record("Controller receipt for fixture operation", session: "first")
    #expect(warning == nil)
    let cold = KilnAssistant(directory: root) { _, _, messages, _ in
        #expect(!messages.contains { $0.content == "turn 0" })
        #expect(messages.contains { $0.content?.contains("Controller receipt for fixture operation") == true })
        return AIMessage(role: "assistant", content: "continued")
    }
    let view = try await cold.useConversation(owner: savedOwner, name: "work", session: "new", configuration: savedConfig)
    #expect(view.events.contains { $0.kind == .operation })
    _ = try await savedAsk(cold, "verify again", session: "new")
}

private final class SavedProgress: @unchecked Sendable {
    private let lock = NSLock(); private var text = ""
    func record(_ event: AIProgress) { if case .answer(let value) = event { lock.withLock { text += value } } }
    func output() -> String { lock.withLock { text } }
}
@Test func authorizationChangesDuringSavedInferenceSuppressLateOutputAndCheckpoint() async throws {
    let root = try savedRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try KilnRuntime(stateDirectory: root); let gate = SavedGate(); let progress = SavedProgress()
    let ai = KilnAssistant(directory: root, streamingCompletion: { _, _, _, _, emit in
        await gate.wait(); emit(.answer("PRIVATE_LATE_RESULT")); return AIMessage(role: "assistant", content: "PRIVATE_LATE_RESULT")
    })
    let commands = KilnCommands(runtime: runtime, assistant: ai)
    try commands.bootstrapIdentity(username: "admin", keys: [savedKey])
    _ = try commands.identities.set(name: "user", role: "operator", key: savedKey, modules: ["a/worker"])
    try KilnStateFile.write(JSONEncoder().encode(savedConfig), to: root.appendingPathComponent("ai.json"))
    let user = commands.forIdentity(name: "user", publicKey: savedKey)
    let owner = try user.aiOwnerFingerprint()
    #expect(await user.execute("ai conversation new work", sessionID: "first").status == 0)
    let worker = Task { await user.execute("ai ask inspect", sessionID: "first", progress: { progress.record($0) }) }
    defer { Task { await gate.release() } }
    for _ in 0..<300 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(await gate.entered)
    _ = try commands.identities.set(name: "user", role: "viewer", key: nil, modules: [])
    await gate.release()
    let result = await worker.value
    #expect(result.status != 0 && !result.text.contains("PRIVATE_LATE_RESULT") && !progress.output().contains("PRIVATE_LATE_RESULT"))
    #expect(!(try await ai.conversationEvents(owner: owner, name: "work")).events.contains { $0.kind == .answer })
    await runtime.shutdown()
}

@Test func checkpointUncertaintyReturnsTheAnswerWithoutReplayingAndRequiresReconciliation() async throws {
    let root = try savedRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let failure = ArchiveFailure(afterCommit: true, failAt: 3)
    let archive = ConversationArchive(directory: root, writer: { try failure.write($0, to: $1) })
    let ai = KilnAssistant(archive: archive) { _, _, _, _ in AIMessage(role: "assistant", content: "Completed once") }
    _ = try await ai.newConversation(owner: savedOwner, name: "work", session: "first", configuration: savedConfig)
    let answer = try await savedAsk(ai, "inspect once")
    #expect(answer.contains("Completed once") && answer.contains("checkpoint unconfirmed"))
    do { _ = try await savedAsk(ai, "must wait"); Issue.record("Ignored uncertain commit") } catch {}
    let cold = KilnAssistant(directory: root)
    let view = try await cold.useConversation(owner: savedOwner, name: "work", session: "new", configuration: savedConfig)
    #expect(view.events.filter { $0.kind == .request }.count == 1)
    #expect(view.events.filter { $0.kind == .answer }.map(\.text) == ["Completed once"])
}

@Test func savedConversationNamesRetentionAndGlobalCapacityAreBounded() throws {
    let root = try savedRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let archive = ConversationArchive(directory: root)
    for name in ["../escape", "UPPER", "", String(repeating: "a", count: 33)] {
        #expect(throws: (any Error).self) { try archive.create(owner: savedOwner, name: name, config: savedConfig) }
    }
    for i in 0..<32 { _ = try archive.create(owner: savedOwner, name: "saved-\(i)", config: savedConfig) }
    #expect(throws: (any Error).self) { try archive.create(owner: savedOwner, name: "overflow", config: savedConfig) }
    for days in [0, 31] { #expect(throws: (any Error).self) { try archive.retention(owner: savedOwner, name: "saved-0", days: days) } }
    try archive.retention(owner: savedOwner, name: "saved-0", days: 1)
    #expect(try archive.lookup(owner: savedOwner, name: "saved-0").retentionDays == 1)
}

@Test func providerVisibleThinkingIsSavedAcrossColdResumeButNeverUsedAsModelContext() async throws {
    let root = try savedRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let ai = KilnAssistant(directory: root, streamingCompletion: { _, _, _, _, emit in
        emit(.reasoning("Visible provider summary: checking current health."))
        emit(.snapshot("")); emit(.answer("Completed check"))
        var result = AIMessage(role: "assistant", content: "Completed check")
        result.providerItems = ["OPAQUE_NOT_VISIBLE"]
        return result
    })
    _ = try await ai.newConversation(owner: savedOwner, name: "thinking", session: "first", configuration: savedConfig)
    _ = try await savedAsk(ai, "Inspect")
    let cold = KilnAssistant(directory: root) { _, _, messages, _ in
        #expect(!messages.contains { $0.content?.contains("Visible provider summary") == true })
        return AIMessage(role: "assistant", content: "Resumed")
    }
    let view = try await cold.useConversation(owner: savedOwner, name: "thinking", session: "cold", configuration: savedConfig)
    let event = try #require(view.events.first { $0.kind == .reasoning })
    #expect(event.text == "Visible provider summary: checking current health.")
    #expect(event.source?.model == savedConfig.model)
    #expect(!String(decoding: try Data(contentsOf: root.appendingPathComponent("ai-conversations/index.json")), as: UTF8.self).contains("OPAQUE_NOT_VISIBLE"))
    _ = try await savedAsk(cold, "Continue", session: "cold")
}

@Test func failedTurnRetainsVisibleThinkingAndLimitHasExplicitNotice() async throws {
    let root = try savedRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let ai = KilnAssistant(directory: root, streamingCompletion: { _, _, _, _, emit in
        emit(.reasoning("Partial provider-visible activity"))
        throw AIError.message("fixture unavailable")
    })
    _ = try await ai.newConversation(owner: savedOwner, name: "interrupted-thinking", session: "first", configuration: savedConfig)
    do { _ = try await savedAsk(ai, "Inspect"); Issue.record("Expected failure") } catch {}
    let view = try await ai.conversationEvents(owner: savedOwner, name: "interrupted-thinking", after: 0)
    #expect(view.events.contains { $0.kind == .reasoning && $0.text == "Partial provider-visible activity" })
    let log = VisibleThinkingLog()
    log.receive(.reasoning(String(repeating: "a", count: 131073)))
    log.receive(.reasoning("must be omitted"))
    #expect(log.text.hasSuffix("[Visible thinking limit reached: later output omitted.]"))
    #expect(!log.text.contains("must be omitted"))
}
