import Foundation
import Crypto
import NIOSSH
import KilnKit

public struct ServerProfile: Codable, Sendable {
    public let name: String
    public let host: String
    public let port: Int
    public let user: String
    public var key: String?
    public var trustedHostKey: String?
    public var candidateHostKey: String?
}
private struct StoredKey: Codable { let publicKey: String }
private struct Configuration: Codable {
    var namespace = "industries.p.kiln." + UUID().uuidString
    var servers: [String:ServerProfile] = [:]
    var keys: [String:StoredKey] = [:]
}

public actor KilnBastion {
    private var terminals: [String: RemoteTerminal] = [:]
    private var creating: Set<String> = []
    private var closing = false
    private let directory: URL
    private var configuration: Configuration?
    public init(directory: URL) { self.directory = directory }
    private func load() throws {
        guard configuration == nil else { return }
        let file = directory.appendingPathComponent("bastion.json")
        if FileManager.default.fileExists(atPath: file.path) {
            configuration = try JSONDecoder().decode(Configuration.self,from: Data(contentsOf:file))
        } else { configuration = Configuration() }
    }
    private func save() throws {
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(configuration!).write(to:directory.appendingPathComponent("bastion.json"),options:.atomic)
    }
    public static func validate(name:String,host:String,user:String,port:Int) throws {
        let identifier=CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let hostname=identifier.union(CharacterSet(charactersIn:":"))
        guard !name.isEmpty, name.count <= 80, name != ".", name != "..", name.unicodeScalars.allSatisfy(identifier.contains),
              !host.isEmpty, host.count <= 253, !host.hasPrefix("-"), host.unicodeScalars.allSatisfy(hostname.contains),
              !user.isEmpty, user.count <= 80, !user.hasPrefix("-"), user.unicodeScalars.allSatisfy(identifier.contains),
              (1...65535).contains(port) else { throw KilnError.message("Invalid server name, host, user or port") }
    }
    public func add(name:String,host:String,user:String,port:Int) throws -> String {
        try Self.validate(name:name,host:host,user:user,port:port);try load()
        guard configuration!.servers[name] == nil else { throw KilnError.message("Server already exists; remove it before replacing its destination") }
        let old=configuration
        configuration!.servers[name]=ServerProfile(name:name,host:host.lowercased(),port:port,user:user)
        do { try save() } catch { configuration=old;throw error }
        return "Added \(name): \(user)@\(host):\(port). ProxyJump allowed for this exact host/port. Managed execution requires a key and verified host identity."
    }
    public func serverSnapshots() throws -> [ServerSnapshot] {
        try load()
        return try configuration!.servers.values.sorted { $0.name < $1.name }.map {
            ServerSnapshot(name: $0.name, host: $0.host, user: $0.user, port: $0.port, key: $0.key,
                fingerprint: try $0.trustedHostKey.map(Self.fingerprint), candidate: try $0.candidateHostKey.map(Self.fingerprint))
        }
    }
    public func edit(name: String, host: String, user: String, port: Int) throws -> String {
        try Self.validate(name: name, host: host, user: user, port: port)
        var server = try profile(name)
        let changed = server.host != host.lowercased() || server.port != port
        if changed { server.trustedHostKey = nil; server.candidateHostKey = nil }
        let old = configuration
        configuration!.servers[name] = ServerProfile(name: name, host: host.lowercased(), port: port, user: user, key: server.key, trustedHostKey: server.trustedHostKey, candidateHostKey: server.candidateHostKey)
        do { try save() } catch { configuration = old; throw error }
        return "Updated \(name)." + (changed ? " Destination changed: verify and pin its host key again. Existing sessions are unchanged." : "")
    }
    public func generateKey(server: String, name: String) throws -> String {
        _ = try profile(server)
        let message = try createKey(name)
        _ = try assign(server: server, key: name)
        return message + "\nAssigned to " + server + ". Install the public key on that server before connecting."
    }
    public func remove(_ name:String) throws -> String {
        try load();guard configuration!.servers[name] != nil else { throw KilnError.message("Unknown server") }
        let old=configuration;configuration!.servers.removeValue(forKey:name)
        do { try save() } catch { configuration=old;throw error }
        return "Removed \(name). New forwarding requests are denied; existing tunnels are unchanged."
    }
    public func profile(_ name:String) throws -> ServerProfile {
        try load();guard let profile=configuration!.servers[name] else { throw KilnError.message("Unknown server") };return profile
    }
    public func allowForward(host:String,port:Int) throws -> Bool {
        try load()
        return configuration!.servers.values.contains { $0.host == host.lowercased() && $0.port == port }
    }
    public func list() throws -> String {
        try load()
        guard !configuration!.servers.isEmpty else { return "No saved servers. Use: server add <name> <host> <user> [port]" }
        return (["NAME  DESTINATION  USER  KEY  HOST TRUST"] + configuration!.servers.values.sorted { $0.name < $1.name }.map {
            "\($0.name)  \($0.host):\($0.port)  \($0.user)  \($0.key ?? "client-held")  \($0.trustedHostKey == nil ? "unverified" : "pinned")"
        }).joined(separator:"\n")
    }
    public func createKey(_ name:String) throws -> String {
        try Self.validate(name:name,host:"localhost",user:"admin",port:22);try load()
        guard configuration!.keys[name] == nil else { throw KilnError.message("Key already exists") }
        // Only public metadata enters configuration. The private representation stays in Keychain.
        let key=Curve25519.Signing.PrivateKey()
        let publicKey=String(openSSHPublicKey:NIOSSHPrivateKey(ed25519Key:key).publicKey)
        let vault=KeyVault(namespace:configuration!.namespace)
        try vault.store(key.rawRepresentation,name:name)
        configuration!.keys[name]=StoredKey(publicKey:publicKey)
        do { try save() } catch {
            configuration!.keys.removeValue(forKey:name);try? vault.delete(name:name);throw error
        }
        return "Created \(name) in macOS Keychain. Install this PUBLIC key on the destination:\n\(publicKey) kiln-\(name)"
    }
    public func publicKey(_ name:String) throws -> String {
        try load();guard let key=configuration!.keys[name] else { throw KilnError.message("Unknown key") };return key.publicKey
    }
    public func keys() throws -> String {
        try load();return configuration!.keys.keys.sorted().joined(separator:"\n")
    }
    public func deleteKey(_ name:String) throws -> String {
        try load();guard configuration!.keys[name] != nil else { throw KilnError.message("Unknown key") }
        guard !configuration!.servers.values.contains(where:{$0.key == name}) else { throw KilnError.message("Key is assigned to a server; remove that server first") }
        try KeyVault(namespace:configuration!.namespace).delete(name:name)
        configuration!.keys.removeValue(forKey:name);try save();return "Deleted \(name) from Keychain"
    }
    public func assign(server:String,key:String) throws -> String {
        _=try profile(server);_=try publicKey(key)
        let old=configuration;configuration!.servers[server]!.key=key
        do { try save() } catch { configuration=old;throw error }
        return "Assigned \(key) to \(server)"
    }
    public static func fingerprint(_ publicKey:String) throws -> String {
        let parts=publicKey.split(separator:" ")
        guard parts.count >= 2, let bytes=Data(base64Encoded:String(parts[1])) else { throw KilnError.message("Invalid public key") }
        return "SHA256:" + Data(SHA256.hash(data:bytes)).base64EncodedString().replacingOccurrences(of:"=",with:"")
    }
    public func scan(_ name:String) throws -> String {
        let server=try profile(name)
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/ssh-keyscan")
        process.arguments=["-T","3","-t","ed25519","-p",String(server.port),server.host]
        let output=Pipe();process.standardOutput=output;process.standardError=FileHandle.nullDevice
        try process.run();let data=output.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        let lines=String(decoding:data,as:UTF8.self).split(separator:"\n")
        guard let parts=lines.map({$0.split(separator:" ")}).first(where:{$0.count >= 3 && $0[1] == "ssh-ed25519"}) else { throw KilnError.message("No Ed25519 host key received; check reachability and host support") }
        let key="\(parts[1]) \(parts[2])";_=try NIOSSHPublicKey(openSSHPublicKey:key)
        configuration!.servers[name]!.candidateHostKey=key;try save()
        return "UNVERIFIED host key for \(name):\n\(try Self.fingerprint(key))\nVerify this fingerprint out of band, then run: server trust \(name) <fingerprint>"
    }
    public func trust(_ name:String,fingerprint:String) throws -> String {
        let server=try profile(name)
        guard let candidate=server.candidateHostKey, try Self.fingerprint(candidate)==fingerprint else { throw KilnError.message("Fingerprint does not match the scanned candidate") }
        let old=configuration;configuration!.servers[name]!.trustedHostKey=candidate
        do { try save() } catch { configuration=old;throw error }
        return "Pinned host identity for \(name)"
    }
    public func execute(_ name:String,command:String) async throws -> RemoteResult {
        let server=try profile(name)
        guard let keyName=server.key, let pin=server.trustedHostKey else { throw KilnError.message("Assign a key and verify/pin the server host key before managed execution") }
        let raw=try KeyVault(namespace:configuration!.namespace).read(name:keyName)
        let privateKey=try Curve25519.Signing.PrivateKey(rawRepresentation:raw)
        return try await RemoteSSH.execute(server:server,key:NIOSSHPrivateKey(ed25519Key:privateKey),hostKey:NIOSSHPublicKey(openSSHPublicKey:pin),command:command)
    }
    public func createSession(name: String, server nameOfServer: String) async throws -> String {
        try Self.validate(name: name, host: "localhost", user: "admin", port: 22)
        guard !closing, terminals[name] == nil, !creating.contains(name), terminals.count + creating.count < 16 else {
            throw KilnError.message("Session name is in use, runtime is closing, or 16-session limit reached")
        }
        let server = try profile(nameOfServer)
        guard let keyName = server.key, let pin = server.trustedHostKey else {
            throw KilnError.message("Assign a key and verify/pin the server host key first")
        }
        let raw = try KeyVault(namespace: configuration!.namespace).read(name: keyName)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        creating.insert(name); defer { creating.remove(name) }
        let terminal = try await RemoteTerminal.open(name: name, server: server, key: NIOSSHPrivateKey(ed25519Key: key), hostKey: NIOSSHPublicKey(openSSHPublicKey: pin))
        guard !closing else { await terminal.close(); throw KilnError.message("Runtime is closing") }
        terminals[name] = terminal
        return "Created session \(name) on \(nameOfServer). Use session attach \(name). It survives client disconnects and dashboard restarts while the session service stays alive."
    }
    public func session(_ name: String) throws -> RemoteTerminal {
        guard let terminal = terminals[name] else { throw KilnError.message("Unknown session") }
        return terminal
    }
    public func sessionSnapshots() async -> [TerminalSessionSnapshot] {
        let current = terminals.values.sorted { $0.name < $1.name }
        var result: [TerminalSessionSnapshot] = []
        for terminal in current { result.append(await terminal.snapshot()) }
        return result.sorted { $0.name < $1.name }
    }
    public func renameSession(_ name: String, to replacement: String) async throws -> String {
        try Self.validate(name: replacement, host: "localhost", user: "admin", port: 22)
        guard terminals[replacement] == nil, !creating.contains(replacement), !creating.contains(name) else { throw KilnError.message("Session name is in use") }
        let terminal = try session(name)
        // Reserve both names across the async call, so concurrent create/rename cannot replace one.
        creating.insert(name); creating.insert(replacement); defer { creating.remove(name); creating.remove(replacement) }
        try await terminal.rename(replacement)
        guard terminals[name] === terminal else { throw KilnError.message("Session was closed during rename") }
        terminals.removeValue(forKey: name); terminals[replacement] = terminal
        return "Renamed session to " + replacement
    }
    public func closeSession(_ name: String) async throws -> String {
        guard let terminal = terminals.removeValue(forKey: name) else { throw KilnError.message("Unknown session") }
        await terminal.close(); return "Closed session \(name)"
    }
    public func shutdownSessions() async {
        closing = true
        let current = Array(terminals.values); terminals.removeAll()
        for terminal in current { await terminal.close() }
    }

}
