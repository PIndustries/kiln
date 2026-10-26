import Foundation
import KilnAI
import KilnKit

extension KilnCommands {
    func workCommand(_ parts: [String], sessionID: String, progress: @escaping @Sendable (AIProgress) -> Void) async throws -> CommandResult {
        try identities.require(principal)
        let owner = try aiOwnerFingerprint()
        switch parts {
        case let p where p.count >= 4 && p[2] == "start":
            let configuration = try activeAIConfiguration()
            // Use the normal ask parser and its registered-project write scope.
            let ask = ["ai","ask"] + Array(p.dropFirst(3))
            let prompt = p.last ?? ""
            var workspace: String?
            if p.count == 6, p[3] == "--workspace",
               let value = try? JSONDecoder().decode([String:String].self,from:Data(p[4].utf8)), let module = value["module"] {
                _ = try await webDevelopment.tree(module:module)
                workspace = try await workspaces.load(owner:owner,module:module).id
            }
            let workSession = sessionID
            let id = try await aiWork.start(owner:owner,session:workSession,prompt:prompt,workspace:workspace) { id, emit in
                guard try aiOwnerFingerprint() == owner else { throw AIError.message("Worker identity changed") }
                let result = try await aiCommand(ask,sessionID:workSession,progress:emit,pinnedConfiguration:configuration,workerID:id)
                guard result.status == 0 else { throw AIError.message(result.text) }
                return result.text
            }
            return try await observeWork(id,owner:owner,progress:progress)
        case let p where p.count == 4 && p[2] == "watch":
            return try await observeWork(p[3],owner:owner,progress:progress)
        case let p where p.count == 5 && p[2] == "input":
            try await aiWork.enqueue(p[4],id:p[3],owner:owner)
            return CommandResult("Context queued; the agent will pick it up at its next safe step.")
        case let p where p.count == 4 && p[2] == "cancel":
            try await aiWork.cancel(p[3],owner:owner); return CommandResult("Worker cancellation requested.")
        case let p where p.count == 4 && p[2] == "remove":
            try await aiWork.remove(p[3],owner:owner); return CommandResult("Worker removed.")
        case ["ai","work","list"]:
            let rows = try await aiWork.list(owner:owner)
            return CommandResult("Background agents: up to 48 concurrent workers\n"+rows.map { "\($0.id)  \($0.state)  \($0.prompt.prefix(80))" }.joined(separator:"\n"))
        default: throw AIError.message("Use ai work start [--workspace JSON] PROMPT | list | watch/input/cancel/remove ID")
        }
    }
    private func observeWork(_ id: String, owner: String, progress: @escaping @Sendable (AIProgress) -> Void) async throws -> CommandResult {
        let stream = try await aiWork.watch(id,owner:owner)
        for await view in stream {
            try Task.checkCancellation()
            guard try aiOwnerFingerprint() == owner else { throw AIError.message("Worker authorization changed") }
            progress(.work(view))
        }
        let view = try await aiWork.snapshot(id,owner:owner)
        guard try aiOwnerFingerprint() == owner else { throw AIError.message("Worker authorization changed") }
        return CommandResult(view.answer + "\n\nWorker " + id + " [" + view.state + "]" + (view.activity.isEmpty ? "" : "\n"+view.activity),status:view.state == "completed" ? 0 : 1)
    }
}
