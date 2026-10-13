import Foundation
import KilnKit
import KilnVault
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Official CLI device authentication. Only the CLI reads its token format;
/// Kiln keeps the bounded opaque auth.json encrypted in Vault between calls.
public actor GrokCLIAccounts {
    private struct Account: Codable {
        let id: String
        let owner: String
        let executable: String
        var state: String
    }
    private struct Pending {
        let execution: GrokCLIExecution
        let home: URL
        var output = Data()
        var code: String?
    }
    private let directory: URL
    private let vault: KilnVault
    private var accounts: [Account]
    private var pending: [String: Pending] = [:]
    private var inUse: Set<String> = []
    public init(directory: URL, vault: KilnVault) throws {
        self.directory = directory; self.vault = vault
        let lease = try GrokAccountsLock(directory); defer { lease.release() }
        accounts = try Self.readAccounts(directory: directory)
    }
    private func reload() throws { accounts = try Self.readAccounts(directory: directory) }
    private static func readAccounts(directory: URL) throws -> [Account] {
        let file = directory.appendingPathComponent("grok-accounts.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let fd = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw AIError.message("Cannot safely open Grok account metadata") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid(),
              info.st_size >= 0, info.st_size <= 65_536, info.st_mode & 0o077 == 0 else { throw AIError.message("Invalid Grok account metadata file") }
        let records = try JSONDecoder().decode([Account].self, from: handle.read(upToCount: 65_537) ?? Data())
        guard records.count <= 32, Set(records.map(\.id)).count == records.count,
              records.allSatisfy({ UUID(uuidString: $0.id) != nil && !$0.owner.isEmpty && $0.owner.utf8.count <= 2048 && $0.executable.hasPrefix("/") && $0.executable.utf8.count <= 4096 && ["pending", "ready", "cancelled", "failed"].contains($0.state) }) else {
            throw AIError.message("Invalid Grok account metadata")
        }
        return records
    }
    public func accounts(owner: String) throws -> String {
        let lease = try GrokAccountsLock(directory); defer { lease.release() }; try reload()
        let rows = accounts.filter { $0.owner == owner }.map { "\($0.id)  \($0.state)" }
        return rows.isEmpty ? "No Grok accounts for this identity." : rows.joined(separator: "\n")
    }
    private func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try KilnStateFile.write(JSONEncoder().encode(accounts), to: directory.appendingPathComponent("grok-accounts.json"))
    }
    private func index(_ id: String, owner: String) throws -> Int {
        guard let i = accounts.firstIndex(where: { $0.id == id && $0.owner == owner }) else { throw AIError.message("Grok account not found for this identity") }
        return i
    }
    private func secret(_ id: String) -> String { "grok-account-" + id }
    private func scope(_ id: String) -> String { "kiln/grok-" + id }
    public func start(owner: String, executable: URL) throws -> String {
        let lease = try GrokAccountsLock(directory); defer { lease.release() }; try reload()
        guard !owner.isEmpty, owner.utf8.count <= 2048, accounts.count < 32, pending.count < 4 else { throw AIError.message("Grok account or login limit reached") }
        _ = try vault.list() // Verify encrypted storage is usable before starting consent.
        let sandbox = try GrokCLISandbox(executable: executable)
        let home = try GrokCLISandbox.makeHome(), id = UUID().uuidString.lowercased()
        let execution: GrokCLIExecution
        do {
            execution = try sandbox.launch(arguments: ["--no-auto-update", "login", "--device-auth"], timeoutSeconds: 600,
                                           scratch: home, loginDiagnostics: true)
        } catch { try? FileManager.default.removeItem(at: home); throw error }
        accounts.append(Account(id: id, owner: owner, executable: sandbox.executable.path, state: "pending"))
        pending[id] = Pending(execution: execution, home: home)
        do { try save() } catch {
            execution.cancel(); pending.removeValue(forKey: id); accounts.removeAll { $0.id == id }
            Task { await execution.waitForExit(); try? FileManager.default.removeItem(at: home) }
            throw error
        }
        Task { await self.monitor(id: id, execution: execution, home: home) }
        return id
    }
    private func monitor(id: String, execution: GrokCLIExecution, home: URL) async {
        defer {
            execution.cancel(); pending.removeValue(forKey: id)
            Task { await execution.waitForExit(); try? FileManager.default.removeItem(at: home) }
        }
        do {
            var exited = false
            for try await event in execution.output {
                guard let i = accounts.firstIndex(where: { $0.id == id }), accounts[i].state == "pending" else { execution.cancel(); continue }
                switch event {
                case .stdout(let data):
                    guard var state = pending[id], data.count <= 16_384 - state.output.count else { throw AIError.message("Login output exceeded its limit") }
                    state.output.append(data)
                    state.code = Self.deviceCode(from: state.output)
                    pending[id] = state
                case .stderrBytes: break
                case .exited(let code):
                    guard code == 0 else { throw AIError.message("CLI sign-in failed") }
                    exited = true
                }
            }
            let lease = try await completionLease(); defer { lease.release() }; try reload()
            guard exited, let i = accounts.firstIndex(where: { $0.id == id }), accounts[i].state == "pending" else { return }
            try persistCredential(id: id, home: home)
            accounts[i].state = "ready"; try save()
        } catch {
            if let lease = try? GrokAccountsLock(directory) {
                defer { lease.release() }
                if (try? reload()) != nil, let i = accounts.firstIndex(where: { $0.id == id }), accounts[i].state == "pending" {
                    accounts[i].state = "failed"; try? save()
                }
            }
        }
    }
    private func completionLease() async throws -> GrokAccountsLock {
        // Another account may be persisting a refresh. Do not discard a completed
        // device login just because that request currently owns the journal.
        for _ in 0..<1200 {
            if let lease = try? GrokAccountsLock(directory) { return lease }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw AIError.message("Grok account storage remained busy")
    }
    static func deviceCode(from data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        // Only accept a code carried by the official verification URL. Do not
        // expose arbitrary CLI output, credential values or error diagnostics.
        let pattern = #"https://accounts\.x\.ai/oauth2/device\?user_code=([A-Z0-9]{4}-[A-Z0-9]{4})(?:[^A-Z0-9-]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
    public func status(id: String, owner: String) throws -> String {
        let lease = try GrokAccountsLock(directory); defer { lease.release() }; try reload()
        let record = accounts[try index(id, owner: owner)]
        var result = "Grok account \(id): \(record.state)"
        if record.state == "pending", let code = pending[id]?.code {
            result += "\nOpen https://accounts.x.ai/oauth2/device?user_code=\(code)\nConfirm code: \(code)\nOnly approve a code you requested."
        }
        return result
    }
    public func cancel(id: String, owner: String) throws -> String {
        let lease = try GrokAccountsLock(directory); defer { lease.release() }; try reload()
        let i = try index(id, owner: owner)
        guard accounts[i].state == "pending" else { return "Grok login is not pending." }
        accounts[i].state = "cancelled"; pending[id]?.execution.cancel(); try save()
        return "Grok login cancelled."
    }
    private func persistCredential(id: String, home: URL) throws {
        let data = try Self.readCredential(home: home)
        _ = try vault.put(secret(id), value: data.base64EncodedString())
        _ = try vault.grant(secret(id), to: scope(id))
    }
    static func readCredential(home: URL) throws -> Data {
        let directory = home.appendingPathComponent(".grok")
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == geteuid() else {
            throw AIError.message("CLI credential directory is invalid")
        }
        let path = directory.appendingPathComponent("auth.json")
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw AIError.message("CLI did not produce an authentication file") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid(),
              info.st_size > 0, info.st_size <= 12_288, info.st_mode & 0o077 == 0 else {
            throw AIError.message("CLI authentication file must be private and no larger than 12 KiB")
        }
        let data = try file.read(upToCount: 12_289) ?? Data()
        guard !data.isEmpty, data.count <= 12_288 else { throw AIError.message("CLI authentication file exceeded its limit") }
        return data
    }
    public func run(account id: String, owner: String, request: GrokCLIRequest,
                    emit: @escaping @Sendable (AIProgress) -> Void) async throws -> AIMessage {
        let lease = try GrokAccountsLock(directory); defer { lease.release() }; try reload()
        let record = accounts[try index(id, owner: owner)]
        guard record.state == "ready", !inUse.contains(id) else { throw AIError.message("Grok account is not ready or already in use") }
        inUse.insert(id); defer { inUse.remove(id) }
        let encoded = try vault.environment(for: scope(id), bindings: ["AUTH": secret(id)])["AUTH"] ?? ""
        guard let auth = Data(base64Encoded: encoded), !auth.isEmpty, auth.count <= 12_288 else { throw AIError.message("Invalid encrypted CLI credential") }
        let home = try GrokCLISandbox.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let grok = home.appendingPathComponent(".grok")
        try FileManager.default.createDirectory(at: grok, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try KilnStateFile.write(auth, to: grok.appendingPathComponent("auth.json"))
        let sandbox = try GrokCLISandbox(executable: URL(fileURLWithPath: record.executable))
        let worker = GrokCLIWorker { request in
            try sandbox.launch(arguments: request.arguments, timeoutSeconds: request.timeoutSeconds, scratch: home)
        }
        do {
            let message = try await worker.run(request, emit: emit)
            try persistCredential(id: id, home: home)
            return message
        } catch {
            // Capture CLI-managed refresh even on a failed inference, without
            // replacing the original execution error if the encrypted write fails.
            try? persistCredential(id: id, home: home)
            throw error
        }
    }
    public func signOut(id: String, owner: String) throws -> String {
        let lease = try GrokAccountsLock(directory); defer { lease.release() }; try reload()
        let i = try index(id, owner: owner)
        guard !inUse.contains(id), accounts[i].state != "pending" else { throw AIError.message("Cancel or finish this account's active work before signing out") }
        if try vault.list().split(separator: "\n").contains(Substring(secret(id))) {
            _ = try vault.revoke(secret(id), from: scope(id))
            _ = try vault.delete(secret(id))
        }
        accounts.remove(at: i); try save()
        return "Grok account removed from Kiln. Provider-side session revocation remains available in your account."
    }
}

/// Nonblocking interprocess lease. A headless request holds the lease through
/// refresh persistence so a stale process cannot resurrect signed-out accounts.
private final class GrokAccountsLock {
    private var descriptor: Int32
    init(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        descriptor = open(directory.appendingPathComponent("grok-accounts.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw AIError.message("Cannot open Grok account lock") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            close(descriptor); descriptor = -1
            throw AIError.message("Invalid Grok account lock")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); descriptor = -1
            throw AIError.message("Grok account storage is busy; retry after the active request")
        }
    }
    func release() { if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 } }
    deinit { release() }
}
