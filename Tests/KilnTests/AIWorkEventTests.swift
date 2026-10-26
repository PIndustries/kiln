import Foundation
import Testing
import KilnKit
@testable import KilnAI
@testable import KilnTerminal
@testable import KilnCommands

private actor EventGate {
    var started = 0
    private var continuation: CheckedContinuation<Void,Never>?
    func wait() async { started += 1; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private func eventDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]); return root
}
private func eventWait(_ predicate: () async throws -> Bool) async throws {
    for _ in 0..<500 { if try await predicate() { return }; try await Task.sleep(for:.milliseconds(10)) }
    Issue.record("Event acceptance condition timed out")
}
private func allEvents(_ work: AIWorkSessions, _ id: String, owner: String = "owner") async throws -> [AIWorkEvent] {
    var result: [AIWorkEvent] = [], cursor = 0
    while true {
        let page = try await work.events(id,owner:owner,after:cursor)
        guard let last = page.last else { return result }
        result += page; cursor = last.sequence
    }
}
@Test func workerJournalRetainsRawProgressAndReceiptsBeyondTheTerminalViewport() async throws {
    let root = try eventDirectory(); defer { try? FileManager.default.removeItem(at:root) }
    let work = AIWorkSessions(directory:root)
    let reasoning = String(repeating:"visible provider text ",count:9000)
    let id = try await work.start(owner:"owner",session:"test",prompt:"inspect") { id,emit in
        emit(.reasoning(reasoning)); emit(.answer("first answer")); emit(.snapshot("revised answer"))
        emit(.source(AISourcePreview(module:"demo/web",path:"Views/Header.swift",source:"struct Header {}",draft:true)))
        try await work.recordTool(AIWorkEvent(.toolStarted,text:"{}",callID:"one",tool:"inspect_web_preview"),id:id,owner:"owner")
        try await work.recordTool(AIWorkEvent(.toolReturned,text:"HTTP 200: factual controller result",callID:"one",tool:"inspect_web_preview"),id:id,owner:"owner")
        return "Controller receipt, not provider prose"
    }
    for await _ in try await work.watch(id,owner:"owner") {}
    let events = try await allEvents(work,id)
    #expect(events.map(\.sequence) == Array(1...events.count))
    #expect(events.filter { $0.kind == .reasoning }.compactMap(\.text).joined() == reasoning)
    let start = try #require(events.firstIndex { $0.kind == .toolStarted })
    let result = try #require(events.firstIndex { $0.kind == .toolReturned })
    #expect(start < result)
    #expect(events[start].callID == events[result].callID)
    #expect(events.last?.kind == .finished)
    #expect(try await work.snapshot(id,owner:"owner").reasoning.count == 131072)
    let restarted = AIWorkSessions(directory:root)
    #expect(try await restarted.snapshot(id,owner:"owner").answer == "Controller receipt, not provider prose")
    #expect(try await allEvents(restarted,id).count == events.count)
    do { _ = try await restarted.events(id,owner:"other"); Issue.record("Cross-owner events leaked") } catch {}
    try await restarted.remove(id,owner:"owner")
    #expect(try await restarted.list(owner:"owner").isEmpty)
    let again = AIWorkSessions(directory:root)
    #expect(try await again.list(owner:"owner").isEmpty)
    #expect(try await allEvents(again,id).last?.kind == .removed)
}
@Test func workerRestartRestoresProgressAndContextAcknowledgementsWithoutReplayingWork() async throws {
    let root = try eventDirectory(); defer { try? FileManager.default.removeItem(at:root) }
    let work = AIWorkSessions(directory:root), gate = EventGate()
    let id = try await work.start(owner:"owner",session:"test",prompt:"inspect") { _,emit in
        emit(.answer("in progress")); emit(.reasoning("provider-visible explanation"))
        emit(.source(AISourcePreview(module:"demo/web",path:"App.swift",source:"struct Proposed {}",draft:true)))
        await gate.wait(); return "late result from old runtime"
    }
    try await eventWait { await gate.started == 1 }
    let context = try await work.enqueue("keep green",id:id,owner:"owner")
    #expect(try await work.takeContext(id,owner:"owner") == ["keep green"])
    try await work.enqueue("pending guidance",id:id,owner:"owner")
    let restarted = AIWorkSessions(directory:root)
    let snapshot = try await restarted.snapshot(id,owner:"owner")
    #expect(snapshot.state == "interrupted")
    #expect(snapshot.answer == "in progress")
    #expect(snapshot.file?.source == "struct Proposed {}")
    #expect(snapshot.queuedContext == 1 && snapshot.consumedContext == 1)
    #expect(await gate.started == 1)
    let events = try await allEvents(restarted,id)
    #expect(events.first { $0.kind == .contextConsumed }?.contextIDs == [context])
    #expect(events.last?.kind == .interrupted)
    await gate.release()
    for await _ in try await work.watch(id,owner:"owner") {}
    #expect(try await work.snapshot(id,owner:"owner").state == "unconfirmed")
    let finalRuntime = AIWorkSessions(directory:root)
    #expect(try await finalRuntime.snapshot(id,owner:"owner").state == "interrupted")
}
@Test func workerJournalRejectsGapsAndNeverRunsAnythingDuringRecovery() async throws {
    let root = try eventDirectory(); defer { try? FileManager.default.removeItem(at:root) }
    let work = AIWorkSessions(directory:root)
    let id = try await work.start(owner:"owner",session:"test",prompt:"inspect") { _,_ in "done" }
    for await _ in try await work.watch(id,owner:"owner") {}
    let folder = root.appendingPathComponent("ai-work-events/"+id)
    let files = try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    try FileManager.default.removeItem(at:files[0])
    let restarted = AIWorkSessions(directory:root)
    do { _ = try await restarted.list(owner:"owner"); Issue.record("Missing journal prefix accepted") } catch {}
}
@Test func failedToolCheckpointPreventsTheControllerWrite() async throws {
    let ai = KilnAssistant { _,_,_,_ in
        let bytes = try JSONSerialization.data(withJSONObject:["id":"write","type":"function","function":["name":"update_web_source","arguments":"{\"module\":\"demo/web\",\"edits\":\"proposal\"}"]])
        return AIMessage(role:"assistant",content:nil,tool_calls:[try JSONDecoder().decode(AIToolCall.self,from:bytes)])
    }
    do {
        _ = try await ai.ask("change",session:"event-failure",configuration:AIConfiguration(baseURL:"http://127.0.0.1:11434",model:"fixture",secret:"",provider:.ollama),key:"",modules:[ModuleSnapshot(application:"demo",name:"web",version:"1",state:"running",pid:1)],context:"",knowledge:nil,webChange:{ _,_ in Issue.record("Write ran without durable intent"); return "bad" },toolCheckpoint:{ _ in throw AIError.message("simulated disk failure") }) { _,_ in "" }
        Issue.record("Failed checkpoint was ignored")
    } catch { #expect(String(describing:error).contains("simulated disk failure")) }
}
@Test func eventHistoryCanBeReadWhileTheComposerRemainsAttachedToItsWorker() throws {
    var ui = KilnTerminal(); _ = ui.handle(.text("7"))
    _ = ui.handle(.text("inspect")); _ = ui.handle(.enter)
    var worker = AIWorkSnapshot(id:"worker-1",prompt:"inspect",state:"running")
    worker.consumedContext = 1; worker.activity = String(repeating:"long activity ",count:30)
    ui.progress(.work(worker)); _ = ui.handle(.text("/events"))
    #expect(ui.render().contains("1 context consumed"))
    let effects = ui.handle(.enter)
    guard case .workerControl(let command) = effects.first else { Issue.record("No independent history command"); return }
    #expect(try KilnCommands.tokenize(command) == ["ai","work","timeline","worker-1","0"])
    ui.finishWorkerControl(text:"#1 created",status:0)
    #expect(ui.busy && ui.input.isEmpty)
    _ = ui.handle(.text("keep green"))
    guard case .workerControl(let context) = ui.handle(.enter).first else { Issue.record("Composer lost active worker"); return }
    #expect(try KilnCommands.tokenize(context) == ["ai","work","input","worker-1","keep green"])
}
@Test func unsafeEventStorageStopsTheWorkerBeforeItsNextTool() async throws {
    let root = try eventDirectory(); defer { try? FileManager.default.removeItem(at:root) }
    let work = AIWorkSessions(directory:root), gate = EventGate()
    let id = try await work.start(owner:"owner",session:"test",prompt:"inspect") { id,_ in
        await gate.wait()
        try await work.recordTool(AIWorkEvent(.toolStarted,text:"{}",callID:"write",tool:"update_web_source"),id:id,owner:"owner")
        Issue.record("Tool was allowed to run with unsafe event storage")
        return "bad"
    }
    try await eventWait { await gate.started == 1 }
    let lock = root.appendingPathComponent("ai-work-events/.writer-lock")
    let outside = root.appendingPathComponent("outside")
    try Data("untouched".utf8).write(to:outside)
    try FileManager.default.removeItem(at:lock)
    try FileManager.default.createSymbolicLink(at:lock,withDestinationURL:outside)
    await gate.release()
    for await _ in try await work.watch(id,owner:"owner") {}
    #expect(try await work.snapshot(id,owner:"owner").state == "unconfirmed")
    #expect(try String(contentsOf:outside,encoding:.utf8) == "untouched")
    try FileManager.default.removeItem(at:lock)
    let restarted = AIWorkSessions(directory:root)
    #expect(try await restarted.snapshot(id,owner:"owner").state == "interrupted")
    #expect(try await allEvents(restarted,id).allSatisfy { $0.kind != .toolStarted })
}
