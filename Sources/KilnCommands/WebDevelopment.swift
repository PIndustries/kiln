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
        case let p where p.count == 3 && p[1] == "changes":
            let text = try await webDevelopment.changes(module: p[2])
            try authorizeAdmin(); return CommandResult(text)
        default: return CommandResult("web register CONFIG.json / web projects / web source APP/MODULE [OFFSET] / web changes APP/MODULE\nCoding is off until an administrator registers one app source, trusted SDK and explicit autoPublish development grant. macOS isolation is required; no unrestricted shell or repository access.")
        }
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
            return result
        } catch {
            try? identities.audit(principal, verb: "web source update", outcome: "failed-or-unconfirmed", target: module, requestID: request)
            return "Web change failed or unconfirmed: \(error).\nInspect web changes \(module), its registered source and active release before retrying."
        }
    }
}
