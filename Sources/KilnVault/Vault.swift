import Foundation
import Crypto
import KilnKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Portable single-host store. flock coordinates the runtime and local administration.
public struct KilnVault: Sendable {
    private struct Configuration: Codable { let id: String; let keyFile: String }
    private struct Contents: Codable {
        var secrets: [String: String] = [:]
        var grants: [String: Set<String>] = [:]
    }
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appendingPathComponent("vault.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw KilnError.message("Cannot open Vault lock") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw KilnError.message("Cannot lock Vault") }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
    public static func validateName(_ name: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard !name.isEmpty, name.count <= 80, name != ".", name != "..", name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw KilnError.message("Secret names must be 1-80 letters, digits, dots, dashes or underscores")
        }
    }
    private func validateModule(_ module: String) throws {
        let pieces = module.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { throw KilnError.message("Module identity must be application/module") }
        for piece in pieces { try Self.validateName(String(piece)) }
    }
    private var configurationURL: URL { directory.appendingPathComponent("vault-config.json") }
    private var contentsURL: URL { directory.appendingPathComponent("vault.enc") }
    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func initialize(keyFile: URL) throws -> String {
        try locked {
            guard !FileManager.default.fileExists(atPath: configurationURL.path), !FileManager.default.fileExists(atPath: contentsURL.path) else {
                throw KilnError.message("Vault already exists; its key will not be replaced")
            }
            let keyURL = keyFile.standardizedFileURL.resolvingSymlinksInPath()
            let statePath = directory.standardizedFileURL.resolvingSymlinksInPath().path
            guard !keyURL.path.hasPrefix(statePath + "/"), keyURL.path != statePath else {
                throw KilnError.message("Master key must live outside the state directory")
            }
            let fd = open(keyURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { throw KilnError.message("Master key path must be new, with an existing protected parent directory") }
            let key = SymmetricKey(size: .bits256)
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: key.withUnsafeBytes { Data($0) }); try handle.synchronize(); try handle.close()
                let config = Configuration(id: UUID().uuidString, keyFile: keyURL.path)
                try save(Contents(), config: config, key: key)
                try write(JSONEncoder().encode(config), to: configurationURL)
            } catch {
                try? handle.close(); try? FileManager.default.removeItem(at: keyURL)
                try? FileManager.default.removeItem(at: contentsURL)
                throw KilnError.message("Vault initialization failed")
            }
            return "Vault initialized. Keep the master key separate from state backups; losing it makes secrets unrecoverable."
        }
    }
    private func load() throws -> (Contents, Configuration, SymmetricKey) {
        guard let data = try? Data(contentsOf: configurationURL), let config = try? JSONDecoder().decode(Configuration.self, from: data) else {
            throw KilnError.message("Vault is not initialized. On the host run: kiln vault init --state PATH --key-file PATH")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: config.keyFile)
        guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw KilnError.message("Vault master key must be a regular file owned by this user with mode 0600")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: config.keyFile))
        guard bytes.count == 32 else { throw KilnError.message("Invalid Vault master key") }
        let key = SymmetricKey(data: bytes)
        do {
            let box = try AES.GCM.SealedBox(combined: Data(contentsOf: contentsURL))
            let clear = try AES.GCM.open(box, using: key, authenticating: Data(config.id.utf8))
            return (try JSONDecoder().decode(Contents.self, from: clear), config, key)
        } catch { throw KilnError.message("Vault authentication failed; key or encrypted store is invalid") }
    }
    private func save(_ contents: Contents, config: Configuration, key: SymmetricKey) throws {
        let box = try AES.GCM.seal(JSONEncoder().encode(contents), using: key, authenticating: Data(config.id.utf8))
        guard let data = box.combined else { throw KilnError.message("Vault encryption failed") }
        try write(data, to: contentsURL)
    }
    public func put(_ name: String, value: String) throws -> String {
        try Self.validateName(name)
        guard !value.isEmpty, value.utf8.count <= 16384, !value.utf8.contains(0) else { throw KilnError.message("Secret must contain 1-16384 UTF-8 bytes, without NUL") }
        return try locked {
            var (contents, config, key) = try load()
            let exists = contents.secrets[name] != nil
            contents.secrets[name] = value
            try save(contents, config: config, key: key)
            return "\(exists ? "Updated" : "Stored") \(name). Values are never displayed. Restart consumers to use a changed value."
        }
    }
    public func list() throws -> String {
        try locked {
            let (contents, _, _) = try load()
            return contents.secrets.isEmpty ? "Vault is empty." : contents.secrets.keys.sorted().joined(separator: "\n")
        }
    }
    public func grant(_ name: String, to module: String) throws -> String {
        try Self.validateName(name); try validateModule(module)
        return try locked {
            var (contents, config, key) = try load()
            guard contents.secrets[name] != nil else { throw KilnError.message("Unknown secret") }
            contents.grants[module, default: []].insert(name)
            try save(contents, config: config, key: key)
            return "Granted \(module) access to \(name) on its next start."
        }
    }
    public func revoke(_ name: String, from module: String) throws -> String {
        try Self.validateName(name); try validateModule(module)
        return try locked {
            var (contents, config, key) = try load()
            contents.grants[module]?.remove(name)
            try save(contents, config: config, key: key)
            return "Revoked future access. Already-running processes retain received values; stop or restart them and rotate the credential if needed."
        }
    }
    public func grants(_ module: String) throws -> String {
        try validateModule(module)
        return try locked {
            let (contents, _, _) = try load()
            let names = contents.grants[module, default: []].sorted()
            return names.isEmpty ? "No grants for \(module)." : names.joined(separator: "\n")
        }
    }
    public func delete(_ name: String) throws -> String {
        try Self.validateName(name)
        return try locked {
            var (contents, config, key) = try load()
            guard !contents.grants.values.contains(where: { $0.contains(name) }) else { throw KilnError.message("Revoke all grants before deleting this secret") }
            guard contents.secrets.removeValue(forKey: name) != nil else { throw KilnError.message("Unknown secret") }
            try save(contents, config: config, key: key)
            return "Deleted \(name)."
        }
    }
    /// Only the trusted supervisor supplies module identity; no module-facing identity parameter exists.
    public func environment(for module: String, bindings: [String: String]) throws -> [String: String] {
        if bindings.isEmpty { return [:] }
        return try locked {
            let (contents, _, _) = try load()
            var result: [String: String] = [:]
            for (variable, secret) in bindings {
                guard contents.grants[module, default: []].contains(secret), let value = contents.secrets[secret] else {
                    throw KilnError.message("Vault denied \(module) access to \(secret)")
                }
                result[variable] = value
            }
            return result
        }
    }
}
