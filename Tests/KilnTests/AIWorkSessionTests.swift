import Foundation
import Testing
import KilnKit
@testable import KilnAI
@testable import KilnCommands
@testable import KilnTerminal

private actor WorkerGate {
    var started = 0
    var inputs: [String] = []
    private var waiters: [CheckedContinuation<Void,Never>] = []
    func wait() async { started += 1; await withCheckedContinuation { waiters.append($0) } }
    func release() { let saved = waiters; waiters = []; for value in saved { value.resume() } }
    func enqueue(_ text: String) { inputs.append(text) }
    func drain() -> [String] { defer { inputs = [] }; return inputs }
}
private func workDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    return directory
}
private func awaitStarted(_ gate: WorkerGate, _ count: Int) async throws {
    for _ in 0..<500 { if await gate.started >= count { return }; try await Task.sleep(for:.milliseconds(10)) }
    Issue.record("Workers failed to start")
}
@Test func workersRun48ConcurrentlyQueueThe49thAndOutliveObservers() async throws {
    let directory = try workDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
    let work = AIWorkSessions(directory:directory), gate = WorkerGate()
    var ids: [String] = []
    for i in 0..<49 {
        ids.append(try await work.start(owner:"owner",session:"chat-\(i)",prompt:"inspect") { _,emit in
            emit(.answer("part ")); await gate.wait(); emit(.answer("two")); return "complete"
        })
    }
    try await awaitStarted(gate,48)
    #expect(await gate.started == 48)
    #expect(try await work.snapshot(ids[48],owner:"owner").state == "queued")
    let observedID = ids[0]
    let observer = Task { for await _ in try await work.watch(observedID,owner:"owner") { try Task.checkCancellation() } }
    observer.cancel(); _ = try? await observer.value
    #expect(try await work.snapshot(ids[0],owner:"owner").state == "running")
    await gate.release(); try await awaitStarted(gate,49); await gate.release()
    for id in ids { for await _ in try await work.watch(id,owner:"owner") {} }
    #expect(try await work.list(owner:"owner").allSatisfy { $0.state == "completed" })
    #expect(try await work.list(owner:"other").isEmpty)
}
@Test func workerInboxIsOwnerBoundDurableAndConsumedExactlyOnce() async throws {
    let directory = try workDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
    let work = AIWorkSessions(directory:directory), gate = WorkerGate()
    let id = try await work.start(owner:"owner",session:"chat",prompt:"inspect") { _,_ in await gate.wait(); return "done" }
    try await awaitStarted(gate,1)
    do { try await work.enqueue("intrusion",id:id,owner:"other"); Issue.record("Cross-owner context accepted") } catch {}
    try await work.enqueue("Use native Swift views",id:id,owner:"owner")
    #expect(try await work.snapshot(id,owner:"owner").queuedContext == 1)
    #expect(try await work.takeContext(id,owner:"owner") == ["Use native Swift views"])
    #expect(try await work.takeContext(id,owner:"owner").isEmpty)
    #expect(try await work.snapshot(id,owner:"owner").contextMessages == ["Use native Swift views"])
    try await work.enqueue("still pending",id:id,owner:"owner")
    // A newly constructed runtime reconciles active work, never replays its writes.
    let restarted = AIWorkSessions(directory:directory)
    #expect(try await restarted.snapshot(id,owner:"owner").state == "interrupted")
    #expect(try await restarted.snapshot(id,owner:"owner").queuedContext == 1)
    await gate.release()
    for await _ in try await work.watch(id,owner:"owner") {}
    // The restarted runtime committed reconciliation. The old writer cannot
    // overwrite that newer evidence when its suspended runner returns.
    #expect(try await work.snapshot(id,owner:"owner").state == "unconfirmed")
}
private func workerCall(_ name: String) throws -> AIMessage {
    let data = try JSONSerialization.data(withJSONObject:["id":"call","type":"function","function":["name":name,"arguments":"{\"module\":\"demo/web\",\"edits\":\"old plan\"}"]])
    return AIMessage(role:"assistant",content:nil,tool_calls:[try JSONDecoder().decode(AIToolCall.self,from:data)])
}
@Test func injectedContextDiscardsAnInflightToolPlanBeforeAnyWrite() async throws {
    let gate = WorkerGate()
    let ai = KilnAssistant { _,_,messages,_ in
        if messages.contains(where: { $0.role == "user" && $0.content == "Keep the original layout" }) {
            #expect(messages.contains { $0.role == "tool" && $0.content?.contains("Not executed") == true })
            return AIMessage(role:"assistant",content:"Kept original layout")
        }
        await gate.wait(); return try workerCall("update_web_source")
    }
    let result = Task {
        try await ai.ask("Change layout",session:"worker",configuration:AIConfiguration(baseURL:"http://127.0.0.1:11434",model:"fixture",secret:"",provider:.ollama),key:"",modules:[ModuleSnapshot(application:"demo",name:"web",version:"1",state:"running",pid:1)],context:"",knowledge:nil,webChange:{ _,_ in Issue.record("Stale plan published"); return "bad" },additionalContext:{ await gate.drain() }) { _,_ in "" }
    }
    try await awaitStarted(gate,1)
    await gate.enqueue("Keep the original layout"); await gate.release()
    #expect(try await result.value == "Kept original layout")
}
@Test func chatCanSendContextWhileTheWorkerStreamsWithoutStartingAnotherTurn() throws {
    var ui = KilnTerminal(); _ = ui.handle(.text("7"))
    _ = ui.handle(.text("Inspect this app")); _ = ui.handle(.enter)
    var work = AIWorkSnapshot(id:"worker-1",prompt:"Inspect this app",state:"running")
    work.answer = "Inspecting"; ui.progress(.work(work))
    _ = ui.handle(.text("Keep the green theme"))
    let effects = ui.handle(.enter)
    guard case .workerControl(let command) = effects.first else { Issue.record("No independent worker control effect"); return }
    #expect(try KilnCommands.tokenize(command) == ["ai","work","input","worker-1","Keep the green theme"])
    #expect(ui.busy && ui.input.isEmpty)
    #expect(ui.render().contains("queued context"))
    #expect(try KilnCommands.tokenize(ui.workerCancelCommand ?? "") == ["ai","work","cancel","worker-1"])
    ui.finishWorkerControl(text:"Context queued",status:0)
    #expect(ui.busy)
}
@Test func liveAgentDraftIsReadOnlyAndCanBeDetachedForManualBrowsing() throws {
    var ui = WorkspaceUI(module:"demo/web")
    ui.finish(text:"{\"tree\":{\"version\":\"workspace\",\"editable\":true,\"projectRoot\":true,\"files\":[{\"path\":\"App.swift\",\"sha256\":\"a\",\"bytes\":10}]},\"file\":{\"file\":\"App.swift\",\"sha256\":\"a\",\"source\":\"struct Original {}\",\"version\":\"workspace\"}}",status:0)
    ui.showAgentFile(AISourcePreview(module:"demo/web",path:"Views/New.swift",source:"struct Proposed {}",draft:true))
    #expect(ui.render(width:120,height:30,theme:TerminalTheme()).contains("AGENT DRAFT"))
    #expect(ui.render(width:120,height:30,theme:TerminalTheme()).contains("Proposed"))
    #expect(!ui.hasUnsavedEdits)
    _ = ui.handle(.followAgent,width:120,height:30)
    #expect(ui.render(width:120,height:30,theme:TerminalTheme()).contains("Original"))
    ui.showAgentFile(AISourcePreview(module:"demo/web",path:"Views/New.swift",source:"struct Revised {}",draft:true))
    #expect(!ui.render(width:120,height:30,theme:TerminalTheme()).contains("Revised"))
    _ = ui.handle(.followAgent,width:120,height:30)
    #expect(ui.render(width:120,height:30,theme:TerminalTheme()).contains("Revised"))
}

@Test func contextArrivingDuringValidationInvalidatesTheValidatedPlanBeforePublish() async throws {
    let gate = WorkerGate()
    let ai = KilnAssistant { _,_,messages,_ in
        if messages.contains(where: { $0.role == "user" && $0.content == "Stop changing the layout" }) {
            return AIMessage(role:"assistant",content:"No changes published")
        }
        if messages.contains(where: { $0.role == "tool" }) { return try workerCall("update_web_source") }
        return try workerCall("validate_web_source")
    }
    let result = Task {
        try await ai.ask("Change layout",session:"validation-context",configuration:AIConfiguration(baseURL:"http://127.0.0.1:11434",model:"fixture",secret:"",provider:.ollama),key:"",modules:[ModuleSnapshot(application:"demo",name:"web",version:"1",state:"running",pid:1)],context:"",knowledge:nil,webChange:{ _,_ in Issue.record("Old validated plan published"); return "bad" },webValidation:{ _,_ in await gate.wait(); return "Isolated compile passed" },additionalContext:{ await gate.drain() }) { _,_ in "" }
    }
    try await awaitStarted(gate,1)
    await gate.enqueue("Stop changing the layout"); await gate.release()
    #expect(try await result.value == "No changes published")
}

@Test func cancellationWaitsForTheWorkerAndRetainsAReceiptReturnedAfterCancellation() async throws {
    let directory = try workDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
    let work = AIWorkSessions(directory:directory), gate = WorkerGate()
    let id = try await work.start(owner:"owner",session:"chat",prompt:"publish") { _,_ in
        // Models a publication that already crossed its commit boundary.
        await gate.wait(); return "Controller receipt: publication already committed"
    }
    try await awaitStarted(gate,1)
    try await work.cancel(id,owner:"owner")
    #expect(try await work.snapshot(id,owner:"owner").state == "cancelling")
    await gate.release()
    for await _ in try await work.watch(id,owner:"owner") {}
    let view = try await work.snapshot(id,owner:"owner")
    #expect(view.state == "cancelled")
    #expect(view.answer.contains("already committed"))
}
