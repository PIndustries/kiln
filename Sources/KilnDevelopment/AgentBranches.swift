import Foundation
import KilnKit

struct AgentBranch: Codable {
    let worker: String
    let owner: String
    let module: String
    let registration: String
    let base: String
    let created: Date
    var status: String
    var proposal: String?
    var edits: String?
    var result: String?
}

extension WebDevelopment {
    private func branchFolder(module: String, worker: String, owner: String) throws -> URL {
        guard UUID(uuidString: worker) != nil, !owner.isEmpty else { throw KilnError.message("Invalid agent scope") }
        let key = WebIsolation.digest(try JSONEncoder().encode([owner,module,worker]))
        let root = directory.appendingPathComponent("agent-branches")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        try WebFiles.checkDirectory(root)
        return root.appendingPathComponent(key)
    }
    private func registration(_ module: String) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return WebIsolation.digest(try encoder.encode(project(module)))
    }
    private func saveBranch(_ branch: AgentBranch, folder: URL) throws {
        try KilnStateFile.write(JSONEncoder().encode(branch), to: folder.appendingPathComponent("branch.json"))
    }
    private func branch(module: String, worker: String, owner: String, create: Bool = true, checkRegistration: Bool = true) throws -> (URL,AgentBranch,WebFiles) {
        let folder = try branchFolder(module:module,worker:worker,owner:owner)
        if !FileManager.default.fileExists(atPath:folder.path) {
            guard create else { throw KilnError.message("Unknown retained agent proposal") }
            guard try FileManager.default.contentsOfDirectory(atPath:folder.deletingLastPathComponent().path).count < 512 else {
                throw KilnError.message("Agent snapshot retention is full; inspect retained proposals before removing them")
            }
            let files = try WebFiles.read(project(module).configuration)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            try files.save(at:folder,before:true)
            try saveBranch(AgentBranch(worker:worker,owner:owner,module:module,registration:registration(module),base:files.digest,created:Date(),status:"reading"),folder:folder)
        }
        try WebFiles.checkDirectory(folder)
        let record = try JSONDecoder().decode(AgentBranch.self,from:WebFiles.readFile(folder.appendingPathComponent("branch.json"),limit:16384))
        guard record.worker == worker, record.owner == owner, record.module == module,
              try !checkRegistration || record.registration == registration(module) else { throw KilnError.message("Agent project registration changed; retained snapshot cannot publish") }
        let files = try WebFiles.retained(at:folder,before:true)
        guard try files.digest == record.base else { throw KilnError.message("Agent snapshot integrity failed") }
        return (folder,record,files)
    }
    func agentSnapshot(module: String, worker: String, owner: String) throws -> WebFiles {
        try branch(module:module,worker:worker,owner:owner).2
    }
    public func prepareAgent(module: String, worker: String, owner: String, edits: String, limit: Int) throws -> [String:Data] {
        let (folder,varRecord,base) = try branch(module:module,worker:worker,owner:owner)
        guard !agentIntegrating.contains(folder.lastPathComponent), !agentValidating.contains(folder.lastPathComponent) else { throw KilnError.message("Agent proposal is already queued") }
        var record = varRecord
        guard ["reading","unvalidated","validated"].contains(record.status) else { throw KilnError.message("Inspect this retained agent outcome before starting a fresh worker; integration is never replayed automatically") }
        let after = try base.applying(edits,multiFile:project(module).configuration.root != nil,limit:limit)
        try after.save(at:folder)
        record.proposal = try after.digest; record.edits = WebIsolation.digest(Data(edits.utf8)); record.status = "unvalidated"; record.result = nil
        try saveBranch(record,folder:folder)
        return after.files
    }
    public func validateAgentChange(module: String, worker: String, owner: String, edits: String,
                                    target: ApplicationManifest, limit: Int, refactorScope: WebRefactor? = nil,
                                    progress: @escaping @Sendable (String) -> Void,
                                    validate: @escaping @Sendable () throws -> Void) async throws -> String {
        let key = try branchFolder(module:module,worker:worker,owner:owner).lastPathComponent
        guard !agentValidating.contains(key) else { throw KilnError.message("This worker is already validating a proposal") }
        try validate(); try Task.checkCancellation()
        let files = try prepareAgent(module:module,worker:worker,owner:owner,edits:edits,limit:limit)
        agentValidating.insert(key); defer { agentValidating.remove(key) }
        while busy.contains(module) || busy.count >= 2 {
            try validate(); try Task.checkCancellation()
            try await Task.sleep(nanoseconds:100_000_000)
        }
        let result = try await change(module:module,owner:owner,edits:edits,target:target,publish:false,operationLimit:limit,refactorScope:refactorScope,restoring:files,progress:progress,validate:validate,deploy:{ _ in throw KilnError.message("Validation cannot publish") })
        try validateAgent(module:module,worker:worker,owner:owner,edits:edits)
        return result
    }
    public func validateAgent(module: String, worker: String, owner: String, edits: String) throws {
        let (folder,varRecord,_) = try branch(module:module,worker:worker,owner:owner,create:false)
        var record = varRecord
        guard record.status == "unvalidated", record.edits == WebIsolation.digest(Data(edits.utf8)),
              try WebFiles.retained(at:folder).digest == record.proposal else { throw KilnError.message("Agent proposal changed during validation") }
        record.status = "validated"; try saveBranch(record,folder:folder)
    }
    /// File-level three-way merge. Ambiguous same-file edits are retained, never guessed.
    static func mergeAgent(base: WebFiles, proposal: WebFiles, current: WebFiles) throws -> WebFiles {
        var merged = current
        for path in Set(base.files.keys).union(proposal.files.keys) where base.files[path] != proposal.files[path] {
            guard current.files[path] == base.files[path] || current.files[path] == proposal.files[path] else {
                throw KilnError.message("Concurrent source conflict in \(path). Agent proposal retained; inspect it before rebasing.")
            }
            merged.files[path] = proposal.files[path]
        }
        try merged.validate(); return merged
    }
    public func integrateAgent(module: String, worker: String, owner: String, edits: String,
                               validate: @escaping @Sendable () throws -> Void,
                               publish: @escaping @Sendable ([String:Data],String) async throws -> String) async throws -> String {
        let (folder,varRecord,base) = try branch(module:module,worker:worker,owner:owner,create:false)
        let key = folder.lastPathComponent
        guard !agentIntegrating.contains(key), !agentValidating.contains(key), agentQueue.count < 64 else { throw KilnError.message("Agent integration queue is full or proposal is already queued") }
        var record = varRecord
        guard record.status == "validated", record.edits == WebIsolation.digest(Data(edits.utf8)) else {
            throw KilnError.message("Validate this exact agent proposal before publication; interrupted integrations are never replayed")
        }
        let proposal = try WebFiles.retained(at:folder)
        guard try proposal.digest == record.proposal else { throw KilnError.message("Agent proposal integrity failed") }
        try validate(); try Task.checkCancellation()
        record.status = "queued"; try saveBranch(record,folder:folder)
        agentQueue.append((key,module)); agentIntegrating.insert(key)
        defer { agentQueue.removeAll { $0.0 == key }; agentIntegrating.remove(key) }
        do {
            while agentQueue.first(where: { $0.1 == module })?.0 != key || busy.contains(module) || busy.count >= 2 {
                try validate(); try Task.checkCancellation()
                try await Task.sleep(nanoseconds:100_000_000)
            }
            try validate(); try Task.checkCancellation()
            _ = try branch(module:module,worker:worker,owner:owner)
            let current = try WebFiles.read(project(module).configuration)
            let merged: WebFiles
            do { merged = try Self.mergeAgent(base:base,proposal:proposal,current:current) }
            catch { record.status = "conflict"; throw error }
            guard merged != current else { record.status = "already-present"; throw KilnError.message("Proposal content is already present; no new publication performed. Inspect the active release.") }
            record.status = "integrating"; try saveBranch(record,folder:folder)
            let result = try await publish(merged.files,current.digest)
            record.status = "integrated"; record.result = result; try saveBranch(record,folder:folder)
            return result
        } catch {
            if ["queued","integrating"].contains(record.status) { record.status = "needs-inspection" }
            record.result = String(describing:error); try? saveBranch(record,folder:folder)
            throw error
        }
    }
    public func agentHistory(module: String, owner: String) throws -> String {
        _ = try project(module)
        let root = directory.appendingPathComponent("agent-branches")
        guard FileManager.default.fileExists(atPath:root.path) else { return "No retained agent proposals" }
        try WebFiles.checkDirectory(root)
        var rows = [AgentBranch]()
        for folder in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).prefix(512) {
            try WebFiles.checkDirectory(folder)
            var row = try JSONDecoder().decode(AgentBranch.self,from:WebFiles.readFile(folder.appendingPathComponent("branch.json"),limit:16384))
            guard row.owner == owner, row.module == module else { continue }
            if ["queued","integrating"].contains(row.status), !agentIntegrating.contains(folder.lastPathComponent) { row.status = "interrupted-needs-inspection" }
            rows.append(row)
        }
        return String(decoding:try JSONEncoder().encode(rows.sorted { $0.created < $1.created }),as:UTF8.self)
    }
    public func agentDiff(module: String, worker: String, owner: String) throws -> String {
        let (folder,record,base) = try branch(module:module,worker:worker,owner:owner,create:false,checkRegistration:false)
        let proposal = try WebFiles.retained(at:folder)
        guard try proposal.digest == record.proposal else { throw KilnError.message("Agent proposal integrity failed") }
        return try DevelopmentGit(directory:folder.appendingPathComponent("diff")).diff(before:base.files,after:proposal.files)
    }
    public func agentFiles(module: String, worker: String, owner: String, proposed: Bool) throws -> String {
        let (folder,record,base) = try branch(module:module,worker:worker,owner:owner,create:false,checkRegistration:false)
        let snapshot = try proposed ? WebFiles.retained(at:folder) : base
        if proposed, try snapshot.digest != record.proposal { throw KilnError.message("Agent proposal integrity failed") }
        let files = snapshot.files.mapValues { String(decoding:$0,as:UTF8.self) }
        return String(decoding:try JSONEncoder().encode(files),as:UTF8.self)
    }
}

extension WebDevelopment {
    public func reviewAgent(module: String, worker: String, owner: String, path: String? = nil) throws -> String {
        let (folder,record,base) = try branch(module:module,worker:worker,owner:owner,create:false,checkRegistration:false)
        guard record.proposal != nil else { throw KilnError.message("This worker has not saved a proposed change yet. Refresh after validation begins.") }
        let proposal = try WebFiles.retained(at:folder), current = try WebFiles.read(project(module).configuration)
        guard try proposal.digest == record.proposal else { throw KilnError.message("Agent proposal integrity failed") }
        let changed = Set(base.files.keys).union(proposal.files.keys).filter { base.files[$0] != proposal.files[$0] }.sorted()
        guard let selected = path ?? changed.first, changed.contains(selected) else { throw KilnError.message("No proposed change for this file") }
        let before = base.files[selected], after = proposal.files[selected], live = current.files[selected]
        let diff = try DevelopmentGit(directory:folder.appendingPathComponent("diff")).diff(before:before.map { [selected:$0] } ?? [:],after:after.map { [selected:$0] } ?? [:])
        let status = ["queued","integrating"].contains(record.status) && !agentIntegrating.contains(folder.lastPathComponent) ? "interrupted-needs-inspection" : record.status
        let view = AgentFileReview(worker:worker,status:status,files:changed,path:selected,base:before.map { String(decoding:$0,as:UTF8.self) },current:live.map { String(decoding:$0,as:UTF8.self) },proposed:after.map { String(decoding:$0,as:UTF8.self) },currentSHA256:live.map(WebIsolation.digest) ?? "missing",proposalSHA256:try proposal.digest,conflict:live != before && live != after,diff:diff)
        return String(decoding:try JSONEncoder().encode(view),as:UTF8.self)
    }
    /// An explicit operator choice creates a local draft; this never publishes.
    public func stageAgentFile(module: String, worker: String, owner: String, path: String, currentSHA256: String, proposalSHA256: String) throws -> String {
        let (folder,record,_) = try branch(module:module,worker:worker,owner:owner,create:false)
        guard !agentIntegrating.contains(folder.lastPathComponent) else { throw KilnError.message("Wait for integration to finish before staging a file") }
        let proposal = try WebFiles.retained(at:folder), current = try WebFiles.read(project(module).configuration)
        guard try proposal.digest == record.proposal, record.proposal == proposalSHA256,
              (current.files[path].map(WebIsolation.digest) ?? "missing") == currentSHA256 else { throw KilnError.message("Source or proposal changed. Refresh the review before staging.") }
        guard let after = proposal.files[path] else { throw KilnError.message("This proposal deletes the file. Inspect it, then use the workspace's explicit Delete action; nothing was staged.") }
        let before = current.files[path] ?? Data()
        var result = SwiftIDEResult(action:"agent-draft",message:"Agent file staged locally. Review/edit the draft and build before publishing.")
        result.renameFiles = [path:SwiftIDERenameFile(source:String(decoding:before,as:UTF8.self),sha256:current.files[path].map(WebIsolation.digest) ?? "",text:String(decoding:after,as:UTF8.self))]
        return String(decoding:try JSONEncoder().encode(result),as:UTF8.self)
    }
}
