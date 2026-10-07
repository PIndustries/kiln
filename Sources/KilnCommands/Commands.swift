import KilnRuntime
import KilnVault
import KilnKit
import KilnTelemetry
import KilnBastion
import Foundation

public struct CommandResult: Sendable {
    public let text: String
    public let status: Int
    public let disconnect: Bool
    public let attachSession: String?
    public init(_ text: String, status: Int = 0, disconnect: Bool = false, attachSession: String? = nil) {
        self.text = text; self.status = status; self.disconnect = disconnect; self.attachSession = attachSession
    }
}

public struct KilnCommands: Sendable {
    private let runtime: KilnRuntime
    private let bastion: BastionClient
    private let telemetry: KilnTelemetry
    public init(runtime: KilnRuntime) { self.runtime = runtime; self.bastion = BastionClient(directory: runtime.stateDirectory); self.telemetry = KilnTelemetry(diskPath: runtime.stateDirectory.path) }
    public func allowForward(host: String, port: Int) async -> Bool {
        if await runtime.allowIngress(host: host, port: port) { return true }
        return (try? await bastion.allowForward(host: host, port: port)) ?? false
    }
    public func observations() -> AsyncStream<Observation> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                while !Task.isCancelled {
                    let host = await telemetry.sample()
                    let modules = await runtime.snapshot()
                    continuation.yield(Observation(modules: modules, host: host))
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    public func management() async -> ManagementSnapshot {
        do {
            return ManagementSnapshot(servers:try await bastion.serverSnapshots(),sessions:try await bastion.sessionSnapshots(),keys:try await bastion.keys().split(separator:"\n").map(String.init))
        } catch { return ManagementSnapshot(error:"Session service unavailable; terminal state is unknown. \(error)") }
    }
    public func sessions() async -> [TerminalSessionSnapshot] { (try? await bastion.sessionSnapshots()) ?? [] }
    public func session(_ name: String) async throws -> RemoteTerminalClient { try await bastion.session(name) }
    public func startSessionService() async throws { try await bastion.start() }
    public func servers() async -> [ServerSnapshot] { (try? await bastion.serverSnapshots()) ?? [] }
    public func keyNames() async -> [String] { ((try? await bastion.keys()) ?? "").split(separator: "\n").map(String.init) }
    public func snapshot() async -> [ModuleSnapshot] { await runtime.snapshot() }
    public func putSecret(name: String, value: String) -> CommandResult {
        do { return CommandResult(try runtime.vault.put(name, value: value)) }
        catch { return CommandResult("Vault write failed: \(error)", status: 1) }
    }
    public func execute(_ line: String) async -> CommandResult {
        var parts: [String]
        do { parts = try Self.tokenize(line) }
        catch { return CommandResult("Unclosed quote or trailing escape", status: 2) }
        if parts.first == "kiln" { parts.removeFirst() }
        if parts.isEmpty { return CommandResult("") }
        do {
            if parts.first == "server" || parts.first == "key" { return try await bastionCommand(parts) }
            if parts.first == "vault" {
                switch parts {
                case ["vault", "help"]:
                    return CommandResult("vault put <name>             Hidden input in the SSH dashboard (creates or replaces)\nvault list                   Secret names only\nvault grant <module> <name>   Allow this module to receive one named secret\nvault revoke <module> <name>  Block future delivery; existing processes retain values\nvault grants <module>        List explicit grants\nvault delete <name>          Delete an unassigned secret\nManifest secrets maps environment-variable names to secret names. Grants are checked on every process start. No reveal command. Headless import: kiln vault put NAME --state PATH < secret-file")
                case ["vault", "list"]: return CommandResult(try runtime.vault.list())
                case let p where p.count == 3 && p[1] == "grants": return CommandResult(try runtime.vault.grants(p[2]))
                case let p where p.count == 3 && p[1] == "delete": return CommandResult(try runtime.vault.delete(p[2]))
                case let p where p.count == 4 && p[1] == "grant": return CommandResult(try runtime.vault.grant(p[3], to: p[2]))
                case let p where p.count == 4 && p[1] == "revoke": return CommandResult(try runtime.vault.revoke(p[3], from: p[2]))
                default: return CommandResult("Use vault help. Secret entry requires vault put NAME in the SSH dashboard; never include a value in the command.", status: 2)
                }
            }
            switch parts {
            case let p where p.count == 4 && p[0] == "session" && p[1] == "open":
                let text = try await bastion.createSession(name:p[2],server:p[3])
                return CommandResult(text,attachSession:p[2])
            case let p where p.count == 4 && p[0] == "session" && p[1] == "rename":
                return CommandResult(try await bastion.renameSession(p[2],to:p[3]))
            case ["session", "help"]:
                return CommandResult("session new <name> <server>  Create a persistent remote terminal\nsession open <name> <server> Create and attach from the dashboard\nsession list                 List terminals\nsession attach <name>        Attach from an interactive SSH PTY\nsession rename <old> <new>   Rename a detached terminal\nsession close <name>         End a terminal and its remote connection\nCtrl-B then d/w detaches to Kiln; n/p switches sessions; Ctrl-B twice sends Ctrl-B.\nSessions survive client disconnects, including dashboard restart while the session service stays alive. Service restart, host reboot or destination/network loss ends them.")
            case ["session", "list"]:
                let list = try await bastion.sessionSnapshots()
                return CommandResult(list.isEmpty ? "No sessions. Use session new <name> <server>" : (["NAME  SERVER  STATE  VIEWER"] + list.map { "\($0.name)  \($0.server)  \($0.state)  \($0.attached ? "attached" : "detached")" }).joined(separator: "\n"))
            case let p where p.count == 4 && p[0] == "session" && p[1] == "new":
                return CommandResult(try await bastion.createSession(name: p[2], server: p[3]))
            case let p where p.count == 3 && p[0] == "session" && p[1] == "attach":
                _ = try await bastion.session(p[2])
                return CommandResult("Attaching \(p[2])", attachSession: p[2])
            case let p where p.count == 3 && p[0] == "session" && p[1] == "close":
                return CommandResult(try await bastion.closeSession(p[2]))
            case ["help"]:
                return CommandResult("""
                Kiln \(KilnVersion.current) development shell
                status                  Runtime status
                metrics                 Host CPU, memory, disk, uptime and load
                app list                Installed applications and process state
                app install <manifest>  Install a trusted local executable release
                app deploy <manifest>   Stage, health-check and switch ingress to a release
                app rollback <name>     Health-check and restore the previous release
                app releases <name>     Active/previous versions and ingress address
                app start <name>        Start a separate application process
                app stop <name>         Stop an application
                app restart <name>      Stop and start an application
                app health <name>       Check its configured HTTP health endpoint
                app logs <name>         Last 8 KiB of application logs
                vault help              Encrypted credentials and per-module grants
                server help             Saved servers, jump forwarding and managed SSH
                key help                Keychain-backed Ed25519 keys
                session help            Persistent remote terminals and switching
                exit                    Disconnect this session
                Quote paths containing spaces. Tab completion is available in the command drawer.
                """)
            case ["metrics"]: return CommandResult(await telemetry.sample().summary)
            case ["status"]: return CommandResult("Kiln runtime running\nRelease: \(KilnVersion.current)\nMode: single node\nApplication isolation: OS processes\nAutomatic restart and clustering: not implemented")
            case ["app", "list"]: return CommandResult(await runtime.list())
            case ["exit"], ["quit"]: return CommandResult("Goodbye.", disconnect: true)
            default:
                guard parts.count == 3, parts[0] == "app" else { return CommandResult("Unknown command. Run help.", status: 2) }
                let name = parts[2]
                switch parts[1] {
                case "deploy": return CommandResult(try await runtime.deploy(path: name))
                case "rollback": return CommandResult(try await runtime.rollback(name))
                case "releases": return CommandResult(try await runtime.releases(name))
                case "install": return CommandResult(try await runtime.install(path: name))
                case "start": return CommandResult(try await runtime.start(name))
                case "stop": return CommandResult(try await runtime.stop(name))
                case "restart":
                    _ = try await runtime.stop(name)
                    return CommandResult(try await runtime.start(name))
                case "health": return CommandResult(try await runtime.health(name))
                case "logs": return CommandResult(try await runtime.logs(name))
                default: return CommandResult("Unknown app operation", status: 2)
                }
            }
        } catch { return CommandResult("Error: \(error)", status: 1) }
    }
}

extension KilnCommands {
    /// Quotes and escapes are parsed as arguments only. Never invokes a host shell.
    public static func tokenize(_ line: String) throws -> [String] {
        var result: [String] = []; var word = ""; var quote: Character?; var escape = false; var active = false
        for character in line {
            if escape { word.append(character); escape = false; active = true; continue }
            if character == "\\" && quote != "'" { escape = true; active = true; continue }
            if let current = quote {
                if character == current { quote = nil } else { word.append(character) }
                continue
            }
            if character == "\"" || character == "'" { quote = character; active = true }
            else if character.isWhitespace {
                if active { result.append(word); word = ""; active = false }
            } else { word.append(character); active = true }
        }
        guard quote == nil, !escape else { throw KilnError.message("Invalid quoting") }
        if active { result.append(word) }
        return result
    }
}

private extension KilnCommands {
    func bastionCommand(_ p: [String]) async throws -> CommandResult {
        switch p {
        case ["server", "help"], ["key", "help"]:
            return CommandResult("""
            server add <name> <host> <user> [port]   Allow forwarding to a saved destination
            server edit <name> <host> <user> [port] Update destination; changed host/port clears trust
            server generate-key <name> <key-name>  Generate and assign a Keychain key
            server list                             List saved servers
            server remove <name>                    Block new tunnels to that destination
            server key <name> <key-name>             Assign a Keychain key
            server scan <name>                      Show an UNVERIFIED host fingerprint
            server trust <name> <fingerprint>        Pin after out-of-band verification
            server exec <name> '<command>'           Execute using pinned identity and Keychain key
            server config <name>                    Print a client-side ProxyJump config
            key create <name>                       Generate Ed25519 directly into Keychain
            key list                                List key names (no secrets)
            key public <name>                       Show the public key for installation
            key delete <name>                       Delete an unassigned Keychain key
            ProxyJump uses your client-held destination identity; it does not forward your agent.
            Managed execution runs the explicitly supplied command on the remote server (15s / 64 KiB limit).
            """)
        case ["server", "list"]: return CommandResult(try await bastion.list())
        case ["key", "list"]: return CommandResult(try await bastion.keys())
        default: break
        }
        if p.count == 3 {
            switch (p[0],p[1]) {
            case ("key","create"): return CommandResult(try await bastion.createKey(p[2]))
            case ("key","public"): return CommandResult(try await bastion.publicKey(p[2]))
            case ("key","delete"): return CommandResult(try await bastion.deleteKey(p[2]))
            case ("server","remove"): return CommandResult(try await bastion.remove(p[2]))
            case ("server","scan"): return CommandResult(try await bastion.scan(p[2]))
            case ("server","config"):
                let server=try await bastion.profile(p[2])
                return CommandResult("Host \(server.name)\n  HostName \(server.host)\n  User \(server.user)\n  Port \(server.port)\n  ProxyJump kiln\n\nDefine Host kiln in your LOCAL SSH config with this Kiln host, port, admin username and identity. Destination host verification remains enabled in your SSH client.")
            default: break
            }
        }
        if p.count == 4, p[0] == "server" {
            if p[1] == "generate-key" { return CommandResult(try await bastion.generateKey(server:p[2],name:p[3])) }
            if p[1] == "key" { return CommandResult(try await bastion.assign(server:p[2],key:p[3])) }
            if p[1] == "trust" { return CommandResult(try await bastion.trust(p[2],fingerprint:p[3])) }
            if p[1] == "exec" {
                let result=try await bastion.execute(p[2],command:p[3]);return CommandResult(result.output,status:result.status)
            }
        }
        if (p.count == 5 || p.count == 6), p[0] == "server", (p[1] == "add" || p[1] == "edit") {
            guard let port=Int(p.count == 6 ? p[5] : "22") else { return CommandResult("Invalid port",status:2) }
            if p[1] == "edit" { return CommandResult(try await bastion.edit(name:p[2],host:p[3],user:p[4],port:port)) }
            return CommandResult(try await bastion.add(name:p[2],host:p[3],user:p[4],port:port))
        }
        return CommandResult("Invalid bastion command; run server help",status:2)
    }
}
