import Foundation
import Crypto
import KilnKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Owned local persistence, with compare-and-swap revisions. Never installs a
/// draft into app source, and never silently overwrites another client's edits.
public actor CodeWorkspaceStore {
    private struct Envelope: Codable { let owner: String; var workspace: CodeWorkspaceRecord }
    private struct Conflict: Codable { let id: String; let owner: String; let module: String; let expectedRevision: Int; let committedRevision: Int; let state: CodeWorkspaceState }
    private let directory: URL
    private var uncertain: Set<String> = []
    public init(directory: URL) { self.directory = directory.appendingPathComponent("code-workspaces",isDirectory:true) }
    private func key(owner: String, module: String) throws -> String {
        guard !owner.isEmpty, owner.utf8.count <= 256, module.split(separator:"/").count == 2,
              module.utf8.count <= 180, module.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-/".contains($0)) }) else { throw KilnError.message("Invalid workspace scope") }
        return SHA256.hash(data:Data((owner+"\n"+module).utf8)).map { String(format:"%02x",$0) }.joined()
    }
    private func validate(_ state: CodeWorkspaceState) throws {
        guard WebFiles.validPath(state.path), (0...65536).contains(state.cursor), (0...1_000_000).contains(state.offset),
              (0...262144).contains(state.horizontal), (1000...9000).contains(state.dividerShare), state.buffers.count <= 32,
              state.buffers.values.reduce(0,{ $0+$1.source.utf8.count+$1.draft.utf8.count }) <= 524288 else { throw KilnError.message("Invalid workspace state or recovery storage limit exceeded") }
        for (path,buffer) in state.buffers {
            guard WebFiles.validPath(path), buffer.source.utf8.count <= 65536, buffer.draft.utf8.count <= 65536,
                  (0...buffer.draft.count).contains(buffer.cursor), (0...1_000_000).contains(buffer.offset), (0...262144).contains(buffer.horizontal),
                  buffer.isNew ? buffer.sha256.isEmpty : buffer.sha256.count == 64 && buffer.sha256.allSatisfy(\.isHexDigit) else { throw KilnError.message("Invalid recovery buffer") }
            if !buffer.isNew { guard WebIsolation.digest(Data(buffer.source.utf8)) == buffer.sha256 else { throw KilnError.message("Recovery base hash does not match its source") } }
        }
    }
    private func locked<T>(_ key: String, body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try privateDirectory(directory)
        let fd = open(directory.appendingPathComponent(key+".lock").path,O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,mode_t(0o600))
        guard fd >= 0 else { throw KilnError.message("Workspace lock unavailable") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              flock(fd,LOCK_EX | LOCK_NB) == 0 else { throw KilnError.message("Workspace is busy or its lock is unsafe; local edits retained") }
        defer { _ = flock(fd,LOCK_UN) }
        return try body()
    }
    private func privateDirectory(_ url: URL) throws {
        try WebFiles.checkDirectory(url)
        let permissions = (try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        guard permissions & 0o077 == 0 else {
            throw KilnError.message("Workspace recovery directory must be private")
        }
    }
    public func load(owner: String, module: String) throws -> CodeWorkspaceRecord {
        let key = try key(owner:owner,module:module)
        return try locked(key) { try read(owner:owner,module:module,key:key) }
    }
    private func read(owner: String, module: String, key: String) throws -> CodeWorkspaceRecord {
        guard !uncertain.contains(key) else { throw KilnError.message("Workspace save outcome uncertain; restart the runtime and inspect saved state") }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try privateDirectory(directory)
        let path = directory.appendingPathComponent(key+".json")
        if FileManager.default.fileExists(atPath:path.path) {
            let envelope = try JSONDecoder().decode(Envelope.self,from:WebFiles.readFile(path,limit:2_097_152))
            guard envelope.owner == owner, envelope.workspace.module == module, envelope.workspace.schemaVersion == 1,
                  UUID(uuidString:envelope.workspace.id) != nil, envelope.workspace.revision >= 0 else { throw KilnError.message("Workspace identity or schema mismatch") }
            try validate(envelope.workspace.state)
            return envelope.workspace
        }
        let record = CodeWorkspaceRecord(module:module)
        try write(Envelope(owner:owner,workspace:record),key:key)
        return record
    }
    private func write(_ envelope: Envelope, key: String) throws {
        let bytes = try JSONEncoder().encode(envelope)
        guard bytes.count <= 2_097_152 else { throw KilnError.message("Workspace checkpoint exceeds its encoded storage limit") }
        do { try KilnStateFile.write(bytes,to:directory.appendingPathComponent(key+".json")) }
        catch let error as KilnStateFile.CommitUncertain { uncertain.insert(key); throw error }
    }
    public func conflicts(owner: String, module: String) throws -> [String] {
        let key = try key(owner:owner,module:module), folder = directory.appendingPathComponent("conflicts")
        guard FileManager.default.fileExists(atPath:folder.path) else { return [] }
        try privateDirectory(folder)
        return try FileManager.default.contentsOfDirectory(atPath:folder.path).filter { $0.hasPrefix(key+"-") && $0.hasSuffix(".json") }.map { String($0.dropFirst(key.count+1).dropLast(5)) }.sorted()
    }
    public func recover(owner: String, module: String, conflict id: String, expectedRevision: Int) throws -> CodeWorkspaceRecord {
        guard UUID(uuidString:id) != nil else { throw KilnError.message("Invalid recovery copy ID") }
        let key = try key(owner:owner,module:module)
        try privateDirectory(directory)
        try privateDirectory(directory.appendingPathComponent("conflicts",isDirectory:true))
        let value = try JSONDecoder().decode(Conflict.self,from:WebFiles.readFile(directory.appendingPathComponent("conflicts/"+key+"-"+id+".json"),limit:2_097_152))
        guard value.owner == owner, value.module == module, value.id == id else { throw KilnError.message("Recovery copy scope mismatch") }
        return try save(owner:owner,module:module,update:CodeWorkspaceSave(expectedRevision:expectedRevision,state:value.state))
    }
    public func save(owner: String, module: String, update: CodeWorkspaceSave) throws -> CodeWorkspaceRecord {
        let key = try key(owner:owner,module:module)
        return try locked(key) {
            var current = try read(owner:owner,module:module,key:key)
            try validate(update.state)
            guard current.revision == update.expectedRevision else {
                let conflict = Conflict(id:UUID().uuidString.lowercased(),owner:owner,module:module,expectedRevision:update.expectedRevision,committedRevision:current.revision,state:update.state)
                let folder = directory.appendingPathComponent("conflicts",isDirectory:true)
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]); try privateDirectory(folder)
                let existing = try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.fileSizeKey])
                let bytes = try JSONEncoder().encode(conflict)
                guard existing.count < 256, bytes.count <= 2_097_152,
                      try existing.reduce(0,{ try $0 + ($1.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) })+bytes.count <= 16_777_216 else { throw KilnError.message("Recovery conflict storage full; keep this connection open and export local edits") }
                try KilnStateFile.write(bytes,to:folder.appendingPathComponent(key+"-"+conflict.id+".json"))
                throw KilnError.message("Workspace changed in another connection. Draft saved in recovery copy " + conflict.id + "; inspect web workspace-conflicts " + module + " before recovering.")
            }
            guard current.revision < Int.max else { throw KilnError.message("Workspace revision exhausted") }
            current.revision += 1; current.state = update.state
            try write(Envelope(owner:owner,workspace:current),key:key)
            return current
        }
    }
}
