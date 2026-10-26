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
            let context = try await aiWork.enqueue(p[4],id:p[3],owner:owner)
            return CommandResult("Context queued; ID \(context). The agent will acknowledge consumption at its next safe step; consumption does not mean a change was applied.")
        case let p where (p.count == 4 || p.count == 5) && ["events","timeline"].contains(p[2]):
            guard let after = p.count == 5 ? Int(p[4]) : 0 else { throw AIError.message("Invalid worker event cursor") }
            let events = try await aiWork.events(p[3],owner:owner,after:after)
            guard try aiOwnerFingerprint() == owner else { throw AIError.message("Worker authorization changed") }
            if p[2] == "timeline" {
                let rows = events.map { event in
                    let label = "Event \(event.sequence) / \(event.kind.rawValue)" + (event.tool.map { " / "+$0 } ?? "")
                    let text = (event.text ?? event.file?.path ?? "").replacingOccurrences(of:"\n",with:" ")
                    let context = event.contextIDs.map { " [context "+$0.map { String($0.prefix(8)) }.joined(separator:", ")+"]" } ?? ""
                    return label+context+(text.isEmpty ? "" : "\n  "+String(text.prefix(160))+(text.count > 160 ? " …" : ""))
                }
                return CommandResult("Agent event history / "+p[3]+"\n"+(rows.isEmpty ? "No later events." : rows.joined(separator:"\n"))+"\nNext: /events "+p[3]+" "+String(events.last?.sequence ?? after)+"\nFull text: ai work events "+p[3]+" "+String(after))
            }
            return CommandResult(String(decoding:try JSONEncoder().encode(events),as:UTF8.self))
        case let p where p.count == 4 && p[2] == "cancel":
            try await aiWork.cancel(p[3],owner:owner); return CommandResult("Worker cancellation requested.")
        case let p where p.count == 4 && p[2] == "remove":
            try await aiWork.remove(p[3],owner:owner); return CommandResult("Worker removed from the list; ordered event evidence is retained.")
        case ["ai","work","list"]:
            let rows = try await aiWork.list(owner:owner)
            return CommandResult("Background agents: up to 48 concurrent workers\n"+rows.map { "\($0.id)  \($0.state)  \($0.prompt.prefix(80))" }.joined(separator:"\n"))
        default: throw AIError.message("Use ai work start [--workspace JSON] PROMPT | list | watch/input/cancel/remove ID | events/timeline ID [AFTER-SEQUENCE]")
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
