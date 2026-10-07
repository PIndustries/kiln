import KilnRuntime
import KilnKit
import KilnTelemetry
import KilnBastion
import Foundation

public struct CommandResult: Sendable {
    public let text: String
    public let status: Int
    public let disconnect: Bool
    public init(_ text: String, status: Int = 0, disconnect: Bool = false) {
        self.text = text; self.status = status; self.disconnect = disconnect
    }
}

public struct KilnCommands: Sendable {
    private let runtime: KilnRuntime
    private let bastion: KilnBastion
    private let telemetry: KilnTelemetry
    public init(runtime: KilnRuntime) { self.runtime = runtime; self.bastion = KilnBastion(directory: runtime.stateDirectory); self.telemetry = KilnTelemetry(diskPath: runtime.stateDirectory.path) }
    public func allowForward(host: String, port: Int) async -> Bool { (try? await bastion.allowForward(host: host, port: port)) ?? false }
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
    public func snapshot() async -> [ModuleSnapshot] { await runtime.snapshot() }
    public func execute(_ line: String) async -> CommandResult {
        var parts: [String]
        do { parts = try Self.tokenize(line) }
        catch { return CommandResult("Unclosed quote or trailing escape", status: 2) }
        if parts.first == "kiln" { parts.removeFirst() }
        if parts.isEmpty { return CommandResult("") }
        do {
            if parts.first == "server" || parts.first == "key" { return try await bastionCommand(parts) }
            switch parts {
            case ["help"]:
                return CommandResult("""
                Kiln 0.2 development shell
                status                  Runtime status
                metrics                 Host CPU, memory, disk, uptime and load
                app list                Installed applications and process state
                app install <manifest>  Install a trusted local executable release
                app start <name>        Start a separate application process
                app stop <name>         Stop an application
                app restart <name>      Stop and start an application
                app health <name>       Check its configured HTTP health endpoint
                app logs <name>         Last 8 KiB of application logs
                server help             Saved servers, jump forwarding and managed SSH
                key help                Keychain-backed Ed25519 keys
                exit                    Disconnect this session
                Quote paths containing spaces. Tab completion is available in the command drawer.
                """)
            case ["metrics"]: return CommandResult(await telemetry.sample().summary)
            case ["status"]: return CommandResult("Kiln runtime running\nMode: single node\nApplication isolation: OS processes\nAutomatic restart and clustering: not implemented")
            case ["app", "list"]: return CommandResult(await runtime.list())
            case ["exit"], ["quit"]: return CommandResult("Goodbye.", disconnect: true)
            default:
                guard parts.count == 3, parts[0] == "app" else { return CommandResult("Unknown command. Run help.", status: 2) }
                let name = parts[2]
                switch parts[1] {
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
            if p[1] == "key" { return CommandResult(try await bastion.assign(server:p[2],key:p[3])) }
            if p[1] == "trust" { return CommandResult(try await bastion.trust(p[2],fingerprint:p[3])) }
            if p[1] == "exec" {
                let result=try await bastion.execute(p[2],command:p[3]);return CommandResult(result.output,status:result.status)
            }
        }
        if (p.count == 5 || p.count == 6), p[0] == "server", p[1] == "add" {
            guard let port=Int(p.count == 6 ? p[5] : "22") else { return CommandResult("Invalid port",status:2) }
            return CommandResult(try await bastion.add(name:p[2],host:p[3],user:p[4],port:port))
        }
        return CommandResult("Invalid bastion command; run server help",status:2)
    }
}
