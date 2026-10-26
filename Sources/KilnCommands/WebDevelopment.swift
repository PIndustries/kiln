import Foundation
import KilnKit
import KilnAI
import KilnDevelopment
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension KilnCommands {
    func webCommand(_ parts: [String], sessionID: String = "web-console", progress: @escaping @Sendable (AIProgress) -> Void) async throws -> CommandResult {
        try authorizeAdmin()
        switch parts {
        case let p where p.count == 4 && p[1] == "workspace":
            let owner = try aiOwnerFingerprint()
            _ = try await webDevelopment.tree(module:p[2])
            let record = try await workspaces.load(owner:owner,module:p[2])
            let selected = record.state.buffers[record.state.path]?.isNew == true ? "App.swift" : record.state.path
            let browse: String
            if let value = try? await webDevelopment.browse(module:p[2],path:selected) { browse = value }
            else { browse = try await webDevelopment.browse(module:p[2],path:p[3]) }
            var object = try JSONSerialization.jsonObject(with:Data(browse.utf8)) as! [String:Any]
            object["workspace"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(record))
            let conflicts = try await workspaces.conflicts(owner:owner,module:p[2])
            if !conflicts.isEmpty { object["recoveryNotice"] = "Saved conflicting drafts: \(conflicts.count). Inspect web workspace-conflicts \(p[2]) before recovering." }
            if let worker = try await aiWork.active(owner:owner,workspace:record.id) { object["worker"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(worker)) }
            guard try aiOwnerFingerprint() == owner else { throw KilnError.message("Workspace identity changed") }
            return CommandResult(String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self))
        case let p where p.count == 3 && p[1] == "workspace-conflicts":
            let owner = try aiOwnerFingerprint()
            _ = try await webDevelopment.tree(module:p[2])
            let copies = try await workspaces.conflicts(owner:owner,module:p[2])
            guard try aiOwnerFingerprint() == owner else { throw KilnError.message("Workspace identity changed") }
            return CommandResult(copies.joined(separator:"\n"))
        case let p where p.count == 5 && p[1] == "workspace-recover":
            guard let revision = Int(p[4]) else { throw KilnError.message("Expected workspace revision required") }
            let owner = try aiOwnerFingerprint()
            _ = try await webDevelopment.tree(module:p[2])
            let record = try await workspaces.recover(owner:owner,module:p[2],conflict:p[3],expectedRevision:revision)
            guard try aiOwnerFingerprint() == owner else { throw KilnError.message("Workspace identity changed") }
            return CommandResult(String(decoding:try JSONEncoder().encode(record),as:UTF8.self))
        case let p where p.count == 4 && p[1] == "workspace-save":
            let owner = try aiOwnerFingerprint()
            _ = try await webDevelopment.tree(module:p[2])
            guard p[3].utf8.count <= 2_097_152 else { throw KilnError.message("Workspace checkpoint too large") }
            let update = try JSONDecoder().decode(CodeWorkspaceSave.self,from:Data(p[3].utf8))
            let result = try await workspaces.save(owner:owner,module:p[2],update:update)
            guard try aiOwnerFingerprint() == owner else { throw KilnError.message("Workspace identity changed") }
            return CommandResult(String(decoding:try JSONEncoder().encode(result),as:UTF8.self))
        case let p where (p.count == 6 || p.count == 7) && p[1] == "ide":
            guard p[3] == "rename" ? p.count == 7 : p.count == 6 else { throw KilnError.message("Rename requires a new Swift symbol name") }
            guard let cursor = Int(p[5]) else { throw KilnError.message("Invalid Swift caret offset") }
            let raw = try await webDevelopment.file(module:p[2],path:p[4])
            let object = try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any]
            guard let text = object?["source"] as? String, let hash = object?["sha256"] as? String else { throw KilnError.message("Invalid Swift source") }
            let request = SwiftIDERequest(action:p[3],path:p[4],sha256:hash,text:text,cursor:cursor,newName:p.count == 7 ? p[6] : nil)
            let result = try await webDevelopment.ide(module:p[2],request:request,scope:try aiSessionID(sessionID),progress:{ progress(.status($0)) })
            try authorizeAdmin()
            return CommandResult(String(decoding:try JSONEncoder().encode(result),as:UTF8.self))
        case let p where p.count == 4 && p[1] == "ide":
            guard p[3].utf8.count <= 2_097_152 else { throw KilnError.message("Oversized IDE request") }
            let request = try JSONDecoder().decode(SwiftIDERequest.self,from:Data(p[3].utf8))
            let result = try await webDevelopment.ide(module:p[2],request:request,scope:try aiSessionID(sessionID),progress:{ progress(.status($0)) })
            try authorizeAdmin()
            return CommandResult(String(decoding:try JSONEncoder().encode(result),as:UTF8.self))
        case ["web", "projects"]: return CommandResult(try await webDevelopment.inventory())
        case let p where p.count == 3 && p[1] == "register":
            let url = URL(fileURLWithPath: p[2])
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= 16384 else { throw KilnError.message("Oversized web configuration") }
            let config = try JSONDecoder().decode(WebProjectConfiguration.self, from: bytes)
            let target = try await runtime.developmentTarget(config.module)
            try authorizeAdmin()
            return CommandResult(try await webDevelopment.register(data: bytes, target: target))
        case let p where (p.count == 3 || p.count == 4) && p[1] == "source":
            guard let offset = p.count == 4 ? Int(p[3]) : 0 else { throw KilnError.message("Invalid source offset") }
            let text = try await webDevelopment.source(module: p[2], offset: offset)
            try authorizeAdmin(); return CommandResult(text)
        case let p where p.count == 3 && p[1] == "history":
            return CommandResult(try await webDevelopment.history(module: p[2], currentVersion: await runtime.developmentTarget(p[2]).version))
        case let p where (p.count == 4 || p.count == 5) && p[1] == "browse":
            return CommandResult(try await webDevelopment.browse(module: p[2], path: p[3], change: p.count == 5 ? p[4] : nil))
        case let p where (p.count == 3 || p.count == 4) && p[1] == "tree":
            return CommandResult(try await webDevelopment.tree(module: p[2], change: p.count == 4 ? p[3] : nil))
        case let p where (p.count == 4 || p.count == 5) && p[1] == "file":
            return CommandResult(try await webDevelopment.file(module: p[2], path: p[3], change: p.count == 5 ? p[4] : nil))
        case let p where p.count == 6 && p[1] == "refactor":
            let request = try await webDevelopment.refactor(module: p[2], path: p[3], sha256: p[4], style: p[5])
            return try await aiCommand(["ai", "ask", request.prompt], sessionID: sessionID, progress: progress, webRefactor: request)
        case let p where p.count == 4 && p[1] == "apply-file":
            // Administrator-only local patch import, parallel to web register.
            // Providers have no tool that exposes this host-filesystem command.
            let fd = open(p[3],O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw KilnError.message("Patch file unavailable or a symbolic link") }
            let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true); defer { try? handle.close() }
            var info = stat()
            guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o022 == 0, info.st_size >= 0, info.st_size <= 262144 else { throw KilnError.message("Patch must be an owned regular file, not writable by other users, at most 256 KiB") }
            let bytes = try handle.read(upToCount:262145) ?? Data()
            guard bytes.count <= 262144, let edits = String(data:bytes,encoding:.utf8) else { throw KilnError.message("Patch file must contain at most 256 KiB of UTF-8 JSON") }
            return try await webCommand(["web","apply",p[2],edits],sessionID:sessionID,progress:progress)
        case let p where p.count == 4 && p[1] == "apply":
            let target = try await runtime.developmentTarget(p[2]), owner = try aiOwnerFingerprint()
            let generation = await runtime.snapshot().first(where: { $0.id == p[2] })?.generationFingerprint
            return CommandResult(try await webDevelopment.change(module: p[2], owner: owner, edits: p[3], target: target, operationLimit:32, progress: { progress(.status($0)) }, validate: { try authorizeAdmin() }, deploy: { path in
                try await runtime.deploy(path: path, expectedGeneration: generation, validateAccess: { try authorizeAdmin() })
            }))
        case let p where p.count == 4 && p[1] == "code":
            return CommandResult(try await webDevelopment.code(module: p[2], id: p[3]))
        case let p where p.count == 4 && p[1] == "diff":
            return CommandResult(try await webDevelopment.diff(module: p[2], id: p[3]))
        case let p where p.count == 4 && p[1] == "restore":
            let target = try await runtime.developmentTarget(p[2]), owner = try aiOwnerFingerprint()
            let generation = await runtime.snapshot().first(where: { $0.id == p[2] })?.generationFingerprint
            return CommandResult(try await webDevelopment.restore(module: p[2], id: p[3], owner: owner, target: target, validate: { try authorizeAdmin() }, deploy: { path in
                try await runtime.deploy(path: path, expectedGeneration: generation, validateAccess: { try authorizeAdmin() })
            }))
        case let p where p.count == 4 && p[1] == "preview":
            let text = try await webDevelopment.preview(module: p[2], path: p[3])
            try authorizeAdmin(); return CommandResult(text)
        case let p where (p.count == 4 || p.count == 5) && p[1] == "agent-review":
            let owner = try aiOwnerFingerprint(), text = try await webDevelopment.reviewAgent(module:p[2],worker:p[3],owner:owner,path:p.count == 5 ? p[4] : nil)
            try authorizeAdmin(); guard try aiOwnerFingerprint() == owner else { throw KilnError.message("Agent review authorization changed") }
            return CommandResult(text)
        case let p where p.count == 7 && p[1] == "agent-stage":
            let owner = try aiOwnerFingerprint(), text = try await webDevelopment.stageAgentFile(module:p[2],worker:p[3],owner:owner,path:p[4],currentSHA256:p[5],proposalSHA256:p[6])
            try authorizeAdmin(); guard try aiOwnerFingerprint() == owner else { throw KilnError.message("Agent staging authorization changed") }
            return CommandResult(text)
        case let p where p.count == 3 && p[1] == "agents":
            let owner = try aiOwnerFingerprint(), text = try await webDevelopment.agentHistory(module:p[2],owner:owner)
            try authorizeAdmin(); guard try aiOwnerFingerprint() == owner else { throw KilnError.message("Agent inspection authorization changed") }
            return CommandResult(text)
        case let p where p.count == 4 && p[1] == "agent-diff":
            let owner = try aiOwnerFingerprint(), text = try await webDevelopment.agentDiff(module:p[2],worker:p[3],owner:owner)
            try authorizeAdmin(); guard try aiOwnerFingerprint() == owner else { throw KilnError.message("Agent inspection authorization changed") }
            return CommandResult(text)
        case let p where p.count == 4 && ["agent-base","agent-proposal"].contains(p[1]):
            let owner = try aiOwnerFingerprint(), text = try await webDevelopment.agentFiles(module:p[2],worker:p[3],owner:owner,proposed:p[1] == "agent-proposal")
            try authorizeAdmin(); guard try aiOwnerFingerprint() == owner else { throw KilnError.message("Agent inspection authorization changed") }
            return CommandResult(text)
        case let p where p.count == 3 && p[1] == "changes":
            let text = try await webDevelopment.changes(module: p[2])
            try authorizeAdmin(); return CommandResult(text)
        default: return CommandResult("web register CONFIG.json / web projects / web workspace APP/MODULE FALLBACK-PATH / web workspace-conflicts APP/MODULE / web workspace-recover APP/MODULE COPY-ID EXPECTED-REVISION / web source APP/MODULE [OFFSET] / web changes APP/MODULE / web agents APP/MODULE / web agent-diff APP/MODULE WORKER-ID / web agent-base APP/MODULE WORKER-ID / web agent-proposal APP/MODULE WORKER-ID / web history APP/MODULE / web tree APP/MODULE [CHANGE] / web file APP/MODULE PATH [CHANGE] / web apply APP/MODULE OPERATIONS-JSON / web apply-file APP/MODULE OWNED-PATCH.json / web refactor APP/MODULE PATH SHA256 components|functions / web code APP/MODULE CHANGE / web diff APP/MODULE CHANGE / web restore APP/MODULE CHANGE / web preview APP/MODULE /PATH\nCoding is off until an administrator registers one app source, trusted SDK and explicit autoPublish development grant. macOS isolation is required; no unrestricted shell or repository access.")
        }
    }
    func rollbackService(_ module: String, expectedGeneration: String? = nil) async throws -> String {
        if !(await webDevelopment.isRegistered(module)) { return try await runtime.rollback(module) }
        try authorizeAdmin()
        let owner = try aiOwnerFingerprint(), target = try await runtime.developmentTarget(module)
        let previous = try await runtime.developmentPreviousVersion(module)
        let generation = await runtime.snapshot().first(where: { $0.id == module })?.generationFingerprint
        if let expectedGeneration, generation != expectedGeneration { throw KilnError.message("Release changed since rollback proposal") }
        return try await webDevelopment.rollback(module: module, currentVersion: target.version, previousVersion: previous, owner: owner,
            validate: { try authorizeAdmin() }, perform: { try await runtime.rollback(module, expectedGeneration: generation, validateAccess: { try authorizeAdmin() }) })
    }
    func validateWebChange(module: String, edits: String, expectedOwner: String, expectedContext: String, operationLimit: Int = 8, refactorScope: WebRefactor? = nil, worker: String? = nil,
                           progress: @escaping @Sendable (AIProgress) -> Void) async throws -> String {
        try authorizeAdmin()
        let target = try await runtime.developmentTarget(module)
        try identities.audit(principal, verb: "web source validate", outcome: "authorized", target: module)
        if let worker {
            return try await webDevelopment.validateAgentChange(module:module,worker:worker,owner:expectedOwner,edits:edits,target:target,limit:operationLimit,refactorScope:refactorScope,progress:{ progress(.status($0)) },validate:{
                try authorizeAdmin()
                guard try aiOwnerFingerprint() == expectedOwner, try activeAIConfiguration().contextID == expectedContext else { throw KilnError.message("Validation identity or provider context changed") }
            })
        }
        let result = try await webDevelopment.change(module: module, owner: expectedOwner, edits: edits, target: target, publish: false, operationLimit: operationLimit, refactorScope: refactorScope,
            progress: { text in progress(.status(text)) }, validate: {
                try authorizeAdmin()
                guard try aiOwnerFingerprint() == expectedOwner, try activeAIConfiguration().contextID == expectedContext else {
                    throw KilnError.message("Validation identity or provider context changed")
                }
            }, deploy: { _ in throw KilnError.message("Validation cannot publish") })
        return result
    }
    func publishWebChange(module: String, edits: String, expectedOwner: String, expectedContext: String, operationLimit: Int = 8, refactorScope: WebRefactor? = nil, worker: String? = nil, restoring: [String:Data]? = nil, expectedSource: String? = nil,
                          progress: @escaping @Sendable (AIProgress) -> Void) async throws -> String {
        try authorizeAdmin()
        if let worker {
            progress(.status("Agent proposal queued for integration"))
            return try await webDevelopment.integrateAgent(module:module,worker:worker,owner:expectedOwner,edits:edits,validate: {
                try authorizeAdmin()
                guard try aiOwnerFingerprint() == expectedOwner, try activeAIConfiguration().contextID == expectedContext else { throw KilnError.message("Integration authorization changed") }
            },publish: { files,digest in
                try await publishWebChange(module:module,edits:edits,expectedOwner:expectedOwner,expectedContext:expectedContext,operationLimit:operationLimit,refactorScope:refactorScope,restoring:files,expectedSource:digest,progress:progress)
            })
        }
        let target = try await runtime.developmentTarget(module)
        guard let before = await runtime.snapshot().first(where: { $0.id == module }) else { throw KilnError.message("Unknown web development module") }
        let request = UUID().uuidString.lowercased()
        try identities.audit(principal, verb: "web source update", outcome: "authorized", target: module, requestID: request)
        do {
            let result = try await webDevelopment.change(module: module, owner: expectedOwner, edits: edits, target: target, operationLimit: operationLimit, refactorScope: refactorScope, restoring:restoring, expectedSource:expectedSource,
                progress: { text in progress(.status(text)) }, validate: {
                    try authorizeAdmin()
                    guard try aiOwnerFingerprint() == expectedOwner, try activeAIConfiguration().contextID == expectedContext else { throw KilnError.message("Coding identity or provider context changed") }
                }, deploy: { path in
                    try authorizeAdmin(); try Task.checkCancellation()
                    guard try aiOwnerFingerprint() == expectedOwner, try activeAIConfiguration().contextID == expectedContext,
                          await runtime.snapshot().first(where: { $0.id == module })?.generationFingerprint == before.generationFingerprint else {
                        throw KilnError.message("Development identity, provider or running release changed during build")
                    }
                    return try await runtime.deploy(path: path, expectedGeneration: before.generationFingerprint, validateAccess: {
                        try authorizeAdmin()
                        guard try aiOwnerFingerprint() == expectedOwner, try activeAIConfiguration().contextID == expectedContext else {
                            throw KilnError.message("Development authorization changed before release activation")
                        }
                    })
                })
            try identities.audit(principal, verb: "web source update", outcome: "returned", target: module, requestID: request)
            // Publication has already committed. Inspection failure must never
            // turn this into a failed publish or cause an automatic retry.
            let probe: String
            do {
                probe = try await webDevelopment.preview(module: module, path: "/")
                try authorizeAdmin()
                guard try aiOwnerFingerprint() == expectedOwner, try activeAIConfiguration().contextID == expectedContext else { throw KilnError.message("Context changed") }
            } catch { return result + "\nHTTP root inspection unavailable; publication receipt above remains authoritative." }
            let response = (try? JSONSerialization.jsonObject(with: Data(probe.utf8))) as? [String: Any]
            let status = (response?["status"] as? Int).map(String.init) ?? "unknown"
            return result + "\nHTTP root inspection: " + status + " (server response; browser interactions checked separately)."
        } catch {
            try? identities.audit(principal, verb: "web source update", outcome: "failed-or-unconfirmed", target: module, requestID: request)
            if restoring != nil { throw error }
            return "Web change failed or unconfirmed: \(error).\nInspect web changes \(module), its registered source and active release before retrying."
        }
    }
}
