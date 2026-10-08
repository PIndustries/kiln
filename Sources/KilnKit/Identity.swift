import Foundation

public struct KilnPrincipal: Sendable {
    public let name: String
    public let publicKey: String
    public init(name: String, publicKey: String) { self.name = name; self.publicKey = publicKey }
}
public struct KilnIdentity: Codable, Sendable {
    public var name: String
    public var role: String
    public var keys: [String]
    public var modules: [String]
    public var enabled: Bool
}
/// Shared lock serializes policy edits; reads reload so existing sessions see revocation.
public final class KilnIdentityStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    public init(directory: URL) { self.directory = directory }
    private var file: URL { directory.appendingPathComponent("identities.json") }
    public static func canonicalKey(_ key: String) throws -> String {
        let pieces = key.split(whereSeparator: \.isWhitespace)
        guard pieces.count >= 2, ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa"].contains(String(pieces[0])), Data(base64Encoded: String(pieces[1])) != nil else { throw KilnError.message("Invalid OpenSSH public key") }
        return pieces.prefix(2).joined(separator: " ")
    }
    private func read() throws -> [KilnIdentity] {
        let bytes = try Data(contentsOf: file)
        guard bytes.count <= 1_048_576 else { throw KilnError.message("Identity policy exceeds limit") }
        let identities = try JSONDecoder().decode([KilnIdentity].self, from: bytes)
        guard identities.count <= 256, Set(identities.map(\.name)).count == identities.count else { throw KilnError.message("Invalid identity policy") }
        for identity in identities { try validate(identity) }
        guard identities.contains(where: { $0.enabled && $0.role == "admin" }) else { throw KilnError.message("Identity policy has no active administrator") }
        return identities
    }
    private func validate(_ identity: KilnIdentity) throws {
        guard !identity.name.isEmpty, identity.name.count <= 64, identity.name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }), ["admin", "operator", "viewer"].contains(identity.role), !identity.keys.isEmpty, identity.keys.count <= 16, identity.modules.count <= 128 else { throw KilnError.message("Invalid identity name, role, keys or scopes") }
        for key in identity.keys { _ = try Self.canonicalKey(key) }
        for scope in identity.modules {
            let parts = scope.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }) }) else { throw KilnError.message("Scopes must be exact application/module names") }
        }
    }
    public func bootstrap(name: String, keys: [String]) throws {
        try lock.withLock {
            let marker = directory.appendingPathComponent("identities.initialized")
            if FileManager.default.fileExists(atPath: file.path) {
                _ = try read()
                if !FileManager.default.fileExists(atPath: marker.path) { try KilnStateFile.write(Data("1".utf8), to: marker) }
                return
            }
            guard !FileManager.default.fileExists(atPath: marker.path) else { throw KilnError.message("Identity policy is missing after initialization; restore its backup using local administrator access") }
            let admin = KilnIdentity(name: name, role: "admin", keys: try keys.map(Self.canonicalKey), modules: [], enabled: true)
            try validate(admin)
            try KilnStateFile.write(Data("1".utf8), to: marker)
            try KilnStateFile.write(JSONEncoder().encode([admin]), to: file)
        }
    }
    public func resolve(_ principal: KilnPrincipal?) throws -> KilnIdentity {
        guard let principal else { return KilnIdentity(name: "local-console", role: "admin", keys: [], modules: [], enabled: true) }
        return try lock.withLock {
            guard let identity = try read().first(where: { $0.name == principal.name && $0.enabled && $0.keys.contains(principal.publicKey) }) else { throw KilnError.message("Identity revoked or unauthorized") }
            return identity
        }
    }
    public func require(_ principal: KilnPrincipal?, admin: Bool = false, mutation: Bool = false, module: String? = nil) throws {
        let identity = try resolve(principal)
        guard !admin || identity.role == "admin", !mutation || identity.role != "viewer", module.map({ identity.role == "admin" || identity.modules.isEmpty || identity.modules.contains($0) }) ?? true else { throw KilnError.message("Permission denied") }
    }
    public func list() throws -> String {
        try lock.withLock { try read().map { "\($0.name)  \($0.role)  \($0.enabled ? "enabled" : "revoked")  scopes=\($0.modules.isEmpty ? "all" : $0.modules.joined(separator: ","))" }.joined(separator: "\n") }
    }
    public func set(name: String, role: String, key: String?, modules: [String], revoke: Bool = false) throws -> String {
        try lock.withLock {
            var identities = try read()
            let existing = identities.firstIndex(where: { $0.name == name })
            var identity = existing.map { identities[$0] } ?? KilnIdentity(name: name, role: role, keys: [], modules: modules, enabled: true)
            if revoke { identity.enabled = false }
            else { identity.role = role; identity.modules = modules; identity.enabled = true; if let key { identity.keys = [try Self.canonicalKey(key)] } }
            try validate(identity)
            if let existing { identities[existing] = identity } else { identities.append(identity) }
            guard identities.count <= 256, identities.contains(where: { $0.enabled && $0.role == "admin" }) else { throw KilnError.message("Cannot revoke or demote the last administrator") }
            try KilnStateFile.write(JSONEncoder().encode(identities), to: file)
            return "Identity \(name) \(revoke ? "revoked" : "updated")"
        }
    }
    public func audit(_ principal: KilnPrincipal?, verb: String, outcome: String, target: String? = nil, requestID: String? = nil) throws {
        try lock.withLock {
            let denied = outcome == "denied"
            let folder = directory.appendingPathComponent(denied ? "audit/denied" : "audit")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            if denied {
                // Rejected requests cannot exhaust the durable mutation journal.
                for old in files.prefix(max(0, files.count - 255)) { try FileManager.default.removeItem(at: old) }
            } else {
                let bytes = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
                guard files.count < 4096, bytes < 8_000_000 else { throw KilnError.message("Audit capacity reached; archive audit records through local administration before further changes. Read-only commands remain available.") }
            }
            var record = ["time": Date().ISO8601Format(), "principal": principal?.name ?? "local-console", "action": verb, "outcome": outcome]
            if let requestID { record["requestID"] = requestID }
            if let target { record["target"] = String(target.prefix(256)) }
            let name = String(Int64(Date().timeIntervalSince1970 * 1000)) + "-" + UUID().uuidString + ".json"
            try KilnStateFile.write(JSONEncoder().encode(record), to: folder.appendingPathComponent(name))
        }
    }
}
