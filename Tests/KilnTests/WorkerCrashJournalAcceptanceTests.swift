import Foundation
import Testing
import KilnKit
@testable import KilnAI

/// Invoked twice by the process-crash harness, with a forced kill in between.
/// No live provider, application deployment or external account is involved.
@Test func workerCrashJournalAcceptance() async throws {
    guard let path = ProcessInfo.processInfo.environment["KILN_EVENT_CRASH_STATE"],
          let mode = ProcessInfo.processInfo.environment["KILN_EVENT_CRASH_MODE"] else { return }
    let root = URL(fileURLWithPath:path), work = AIWorkSessions(directory:root)
    if mode == "run" {
        let id = try await work.start(owner:"fixture",session:"crash-proof",prompt:"inspect fixture") { id,emit in
            try KilnStateFile.write(Data("one invocation".utf8),to:root.appendingPathComponent("runner-invocations"))
            emit(.answer("Partial answer before crash"))
            emit(.reasoning("Visible provider explanation before crash"))
            emit(.source(AISourcePreview(module:"fixture/web",path:"App.swift",source:"struct Proposed {}",draft:true)))
            try await work.enqueue("pending guidance",id:id,owner:"fixture")
            try await work.recordTool(AIWorkEvent(.toolStarted,text:"fixture intent only; no deployment is performed",callID:"pending-operation",tool:"fixture_controller_operation"),id:id,owner:"fixture")
            try KilnStateFile.write(Data(id.utf8),to:root.appendingPathComponent("ready"))
            try await Task.sleep(for:.seconds(180))
            Issue.record("Crash harness did not terminate the worker")
            return "unexpected completion"
        }
        for await _ in try await work.watch(id,owner:"fixture") {}
    } else {
        #expect(mode == "recover")
        let id = try String(contentsOf:root.appendingPathComponent("ready"),encoding:.utf8)
        let view = try await work.snapshot(id,owner:"fixture")
        let events = try await work.events(id,owner:"fixture")
        #expect(view.state == "interrupted")
        #expect(view.answer == "Partial answer before crash")
        #expect(view.reasoning == "Visible provider explanation before crash")
        #expect(view.file?.source == "struct Proposed {}")
        #expect(view.queuedContext == 1)
        #expect(events.contains { $0.kind == .toolStarted && $0.callID == "pending-operation" })
        #expect(!events.contains { $0.kind == .toolReturned || $0.kind == .finished })
        #expect(events.last?.kind == .interrupted)
        #expect(try String(contentsOf:root.appendingPathComponent("runner-invocations"),encoding:.utf8) == "one invocation")
        let newID = try await work.start(owner:"fixture",session:"new-work",prompt:"fresh work") { _,_ in "fresh result" }
        for await _ in try await work.watch(newID,owner:"fixture") {}
        #expect(try await work.snapshot(newID,owner:"fixture").state == "completed")
        try KilnStateFile.write(Data("interrupted; progress and pending intent retained; no replay; new work accepted".utf8),to:root.appendingPathComponent("recovered"))
    }
}
