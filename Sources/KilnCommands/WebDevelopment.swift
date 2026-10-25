import Foundation
import KilnKit
import KilnAI
import KilnDevelopment

extension KilnCommands {
    func webCommand(_ parts: [String], progress: @escaping @Sendable (AIProgress) -> Void) async throws -> CommandResult {
        try authorizeAdmin()
        switch parts {
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
        case let p where p.count == 3 && p[1] == "changes":
            let text = try await webDevelopment.changes(module: p[2])
            try authorizeAdmin(); return CommandResult(text)
        default: return CommandResult("web register CONFIG.json / web projects / web source APP/MODULE [OFFSET] / web changes APP/MODULE / web history APP/MODULE / web diff APP/MODULE CHANGE / web restore APP/MODULE CHANGE / web preview APP/MODULE /PATH\nCoding is off until an administrator registers one app source, trusted SDK and explicit autoPublish development grant. macOS isolation is required; no unrestricted shell or repository access.")
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
    func validateWebChange(module: String, edits: String, expectedOwner: String, expectedContext: String,
                           progress: @escaping @Sendable (AIProgress) -> Void) async throws -> String {
        try authorizeAdmin()
        let target = try await runtime.developmentTarget(module)
        try identities.audit(principal, verb: "web source validate", outcome: "authorized", target: module)
        return try await webDevelopment.change(module: module, owner: expectedOwner, edits: edits, target: target, publish: false,
            progress: { text in progress(.status(text)) }, validate: {
                try authorizeAdmin()
                guard try aiOwnerFingerprint() == expectedOwner, try activeAIConfiguration().contextID == expectedContext else {
                    throw KilnError.message("Validation identity or provider context changed")
                }
            }, deploy: { _ in throw KilnError.message("Validation cannot publish") })
    }
    func publishWebChange(module: String, edits: String, expectedOwner: String, expectedContext: String,
                          progress: @escaping @Sendable (AIProgress) -> Void) async throws -> String {
        try authorizeAdmin()
        let target = try await runtime.developmentTarget(module)
        guard let before = await runtime.snapshot().first(where: { $0.id == module }) else { throw KilnError.message("Unknown web development module") }
        let request = UUID().uuidString.lowercased()
        try identities.audit(principal, verb: "web source update", outcome: "authorized", target: module, requestID: request)
        do {
            let result = try await webDevelopment.change(module: module, owner: expectedOwner, edits: edits, target: target,
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
            return "Web change failed or unconfirmed: \(error).\nInspect web changes \(module), its registered source and active release before retrying."
        }
    }
}
