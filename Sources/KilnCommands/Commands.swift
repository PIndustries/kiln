import NIOSSH
import KilnCluster
import KilnRuntime
import KilnAI
import KilnVault
import KilnKit
import KilnTelemetry
import KilnBastion
import Foundation

private enum CommandSyntaxError: Error { case unknown }

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
    private let cluster: KilnCluster?
    private let runtime: KilnRuntime
    private let bastion: BastionClient
    private let telemetry: KilnTelemetry
    private let assistant: KilnAssistant
    private let aiTasks: AITasks
    public let identities: KilnIdentityStore
    public private(set) var principal: KilnPrincipal? = nil
    public func forIdentity(name: String, publicKey: String) -> KilnCommands { var copy = self; copy.principal = KilnPrincipal(name: name, publicKey: (try? KilnIdentityStore.canonicalKey(publicKey)) ?? "invalid"); return copy }
    public func bootstrapIdentity(username: String, keys: [String]) throws { try identities.bootstrap(name: username, keys: keys) }
    public func isAuthorized() -> Bool { (try? identities.resolve(principal)) != nil }
    public func authorizeAdmin() throws { try identities.require(principal, admin: true) }
    public init(runtime: KilnRuntime, cluster: KilnCluster? = nil) { self.assistant = KilnAssistant(); self.cluster = cluster; self.identities = KilnIdentityStore(directory: runtime.stateDirectory); self.aiTasks = AITasks(directory: runtime.stateDirectory); self.runtime = runtime; self.bastion = BastionClient(directory: runtime.stateDirectory); self.telemetry = KilnTelemetry(diskPath: runtime.stateDirectory.path) }
    // Internal dependency injection keeps snapshot tests deterministic without
    // granting the presentation layer authority to create proposals.
    init(runtime: KilnRuntime, assistant: KilnAssistant) {
        self.runtime = runtime; self.assistant = assistant; self.cluster = nil
        self.identities = KilnIdentityStore(directory: runtime.stateDirectory)
        self.aiTasks = AITasks(directory: runtime.stateDirectory)
        self.bastion = BastionClient(directory: runtime.stateDirectory)
        self.telemetry = KilnTelemetry(diskPath: runtime.stateDirectory.path)
    }
    public func aiWorkspace(sessionID: String = "console") async -> AIWorkspaceSnapshot {
        guard (try? identities.resolve(principal)) != nil else {
            return AIWorkspaceSnapshot(error: "Identity revoked or unauthorized")
        }
        let proposals = await assistant.pendingProposals(session: (principal?.name ?? "local-console") + ":" + sessionID)
        var tasks: [AITaskSnapshot] = []
        var taskError: String?
        if (try? authorizeAdmin()) != nil {
            do { tasks = try await aiTasks.snapshots() }
            catch { taskError = "AI task state unavailable" }
        }
        // Re-resolve after actor suspension so an in-flight refresh cannot
        // return the previous role's private task inventory after revocation.
        guard let identity = try? identities.resolve(principal) else {
            return AIWorkspaceSnapshot(error: "Identity revoked or unauthorized")
        }
        let visible = proposals.filter {
            $0.expires > Date() && identity.role != "viewer" &&
            (identity.role == "admin" || identity.modules.isEmpty || identity.modules.contains($0.module))
        }
        return AIWorkspaceSnapshot(proposals: visible, tasks: identity.role == "admin" ? tasks : [],
                                   error: identity.role == "admin" ? taskError : nil)
    }
    public func allowForward(host: String, port: Int) async -> Bool {
        guard (try? authorizeAdmin()) != nil else { return false }
        if await runtime.allowIngress(host: host, port: port) { return true }
        return (try? await bastion.allowForward(host: host, port: port)) ?? false
    }
    public func observations() -> AsyncStream<Observation> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                while !Task.isCancelled {
                    let host = await telemetry.sample()
                    let modules = await snapshot()
                    continuation.yield(Observation(modules: modules, host: host))
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    public func management() async -> ManagementSnapshot {
        guard let identity = try? identities.resolve(principal) else { return ManagementSnapshot(error: "Identity revoked or unauthorized", access: "ACCESS REVOKED") }
        let access = identity.name + " / " + identity.role
        guard identity.role == "admin" else { return ManagementSnapshot(error: "Server, key and remote terminal management requires administrator access.", access: access) }
        do {
            return ManagementSnapshot(servers:try await bastion.serverSnapshots(),sessions:try await bastion.sessionSnapshots(),keys:try await bastion.keys().split(separator:"\n").map(String.init), access: access)
        } catch { return ManagementSnapshot(error:"Session service unavailable; terminal state is unknown. \(error)", access: access) }
    }
    public func sessions() async -> [TerminalSessionSnapshot] { guard (try? authorizeAdmin()) != nil else { return [] }; return (try? await bastion.sessionSnapshots()) ?? [] }
    public func session(_ name: String) async throws -> RemoteTerminalClient { try authorizeAdmin(); return try await bastion.session(name) }
    public func startSessionService() async throws { try await bastion.start() }
    public func servers() async -> [ServerSnapshot] { guard (try? authorizeAdmin()) != nil else { return [] }; return (try? await bastion.serverSnapshots()) ?? [] }
    public func keyNames() async -> [String] { guard (try? authorizeAdmin()) != nil else { return [] }; return ((try? await bastion.keys()) ?? "").split(separator: "\n").map(String.init) }
    public func snapshot() async -> [ModuleSnapshot] { guard let identity = try? identities.resolve(principal) else { return [] }; return await runtime.snapshot().filter { identity.role == "admin" || identity.modules.isEmpty || identity.modules.contains($0.id) } }
    public func putSecret(name: String, value: String) -> CommandResult {
        let requestID = UUID().uuidString.lowercased()
        var admitted = false
        do {
            try authorizeAdmin()
            admitted = true
            try identities.audit(principal, verb: "vault put", outcome: "authorized", requestID: requestID)
            let result = try runtime.vault.put(name, value: value)
            do { try identities.audit(principal, verb: "vault put", outcome: "returned", requestID: requestID) }
            catch { return CommandResult("Vault write returned but its audit outcome could not be recorded. Inspect state before retrying.", status: 1) }
            return CommandResult(result)
        } catch {
            try? identities.audit(principal, verb: "vault put", outcome: admitted ? "failed" : "denied", requestID: requestID)
            return CommandResult("Vault write failed: \(error)", status: 1)
        }
    }
    public func execute(_ line: String, sessionID: String = "console", progress: @escaping @Sendable (AIProgress) -> Void = { _ in }) async -> CommandResult {
        let requestID = UUID().uuidString.lowercased()
        var parsed = (try? Self.tokenize(line)) ?? []
        if parsed.first == "kiln" { parsed.removeFirst() }
        let auditCompletion = !parsed.isEmpty && auditsMutation(parsed) && (try? authorize(parsed)) != nil
        let result = await executeCommand(line, sessionID: sessionID, progress: progress, auditID: requestID)
        guard auditCompletion else { return result }
        let metadata = auditMetadata(parsed)
        do { try identities.audit(principal, verb: metadata.0, outcome: result.status == 0 ? "returned" : "failed", target: metadata.1, requestID: requestID) }
        catch { return CommandResult(result.text + "\nCompletion audit unavailable. Inspect state before retrying. Request: " + requestID, status: 1) }
        return result
    }
    private func executeCommand(_ line: String, sessionID: String, progress: @escaping @Sendable (AIProgress) -> Void, auditID: String) async -> CommandResult {
        var parts: [String]
        do { parts = try Self.tokenize(line) }
        catch { return CommandResult("Unclosed quote or trailing escape", status: 2) }
        if parts.first == "kiln" { parts.removeFirst() }
        if parts.isEmpty { return CommandResult("") }
        let (verb, target) = auditMetadata(parts)
        var authorized = false
        do {
            try authorize(parts)
            authorized = true
            if auditsMutation(parts) { try identities.audit(principal, verb: verb, outcome: "authorized", target: target, requestID: auditID) }
            if parts.first == "node" || parts.first == "cluster" { return try await nodeCommand(parts, requestID: auditID) }
            if parts.first == "identity" { return try identityCommand(parts) }
            if parts.first == "server" || parts.first == "key" { return try await bastionCommand(parts) }
            if parts.first == "ai" { return try await aiCommand(parts, sessionID: (principal?.name ?? "local-console") + ":" + sessionID, progress: progress) }
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
                identity help           Named SSH users, roles and module scopes
                node help               Explicit peer discovery and adoption
                app resources <name>    Worker resource policy and usage
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
                ai help                 Native Erebine chat, reports and proposed operations
                vault help              Encrypted credentials and per-module grants
                server help             Saved servers, jump forwarding and managed SSH
                key help                Keychain-backed Ed25519 keys
                session help            Persistent remote terminals and switching
                exit                    Disconnect this session
                Quote paths containing spaces. Tab completion is available in the command drawer.
                """)
            case ["metrics"]: return CommandResult(await telemetry.sample().summary)
            case ["status"]: return CommandResult("Kiln runtime running\nRelease: \(KilnVersion.current)\nMode: single node\nApplication isolation: OS processes\nAutomatic restart: opt-in, bounded retries\nClustering: \(cluster == nil ? "disabled" : "explicit peer adoption and typed remote operations; no scheduler or automatic failover")")
            case ["app", "list"]: return CommandResult(await visibleModules())
            case ["exit"], ["quit"]: return CommandResult("Goodbye.", disconnect: true)
            default:
                guard parts.count == 3, parts[0] == "app" else { return CommandResult("Unknown command. Run help.", status: 2) }
                let name = parts[2]
                switch parts[1] {
                case "deploy": return CommandResult(try await runtime.deploy(path: name))
                case "rollback": return CommandResult(try await runtime.rollback(name))
                case "resources": return CommandResult(try await runtime.resourceStatus(name))
                case "releases": return CommandResult(try await runtime.releases(name))
                case "install": return CommandResult(try await runtime.install(path: name))
                case "start": return CommandResult(try await runtime.start(name))
                case "stop": return CommandResult(try await runtime.stop(name))
                case "restart": return CommandResult(try await runtime.restart(name))
                case "health": return CommandResult(try await runtime.health(name))
                case "logs": return CommandResult(try await runtime.logs(name))
                default: return CommandResult("Unknown app operation", status: 2)
                }
            }
        } catch is CommandSyntaxError { return CommandResult("Unknown command. Run help.", status: 2) }
        catch is CancellationError { return CommandResult("Stopped waiting. Background tasks continue unless explicitly cancelled.", status: 1) }
        catch { if !authorized { try? identities.audit(principal, verb: verb, outcome: "denied", target: target, requestID: auditID) }; return CommandResult("Error: \(error)", status: 1) }
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


private extension KilnCommands {
    func createAITask(_ prompt: String) async throws -> String {
        try authorizeAdmin()
        let requestID = UUID().uuidString.lowercased()
        try identities.audit(principal, verb: "ai task new", outcome: "authorized", requestID: requestID)
        let result = try await aiTasks.submit(prompt) { id, request, progress in
            try authorizeAdmin()
            let result = try await aiCommand(["ai", "ask", request], sessionID: "task:" + id, progress: progress)
            guard result.status == 0 else { throw AIError.message("Task failed") }
            return result.text
        }
        do { try identities.audit(principal, verb: "ai task new", outcome: "returned", requestID: requestID) }
        catch { throw AIError.message("Task was created but completion audit failed. Inspect ai task list before retrying.") }
        return result
    }
    func aiCommand(_ parts: [String], sessionID: String, progress: @escaping @Sendable (AIProgress) -> Void = { _ in }) async throws -> CommandResult {
        if parts.count >= 3, parts[1] == "task" {
            switch parts {
            case ["ai", "task", "list"]: return CommandResult(try await aiTasks.list())
            case let p where p.count == 4 && p[2] == "show": return CommandResult(try await aiTasks.show(p[3]))
            case let p where p.count == 4 && p[2] == "cancel": return CommandResult(try await aiTasks.cancel(p[3]))
            case let p where p.count == 4 && p[2] == "remove": return CommandResult(try await aiTasks.remove(p[3]))
            case let p where p.count == 4 && p[2] == "watch":
                for await snapshot in try await aiTasks.watch(p[3]) { try Task.checkCancellation(); progress(.snapshot(snapshot)) }
                try Task.checkCancellation()
                return CommandResult(try await aiTasks.show(p[3]))
            case let p where p.count >= 4 && p[2] == "new": return CommandResult(try await createAITask(p.dropFirst(3).joined(separator: " ")))
            default: throw AIError.message("Use ai task new/list/show/watch/cancel/remove")
            }
        }
        if parts == ["ai", "concurrency"] { return CommandResult(try await aiTasks.limit()) }
        if parts.count == 3, parts[1] == "concurrency", let limit = Int(parts[2]) { return CommandResult(try await aiTasks.limit(limit)) }
        let configURL = runtime.stateDirectory.appendingPathComponent("ai.json")
        let knowledgeURL = runtime.stateDirectory.appendingPathComponent("ai-knowledge.json")
        switch parts {
        case ["ai"], ["ai", "help"]:
            return CommandResult("Open the drawer and type ai to chat. /exit leaves chat; /reset clears context; /approve ID executes a proposal; /deny ID declines.\nai ask <question>             Ask using this SSH session's conversation\nai task new/list/show/watch/cancel/remove\nai concurrency [1-48]        Background worker limit (default 4)\nai operations                 Recent approved operation outcomes\nai status                     Provider and knowledge version\nai configure <baseURL> <model> <vault-name>\nai knowledge install <path>   Load a versioned JSON knowledge pack\nai reset                      Clear conversation and proposals\nRead tools: status, modules, host metrics, module health, releases. Proposed operations: start/stop/restart/rollback. No shell, logs or Vault-value tools. Prompts and tool results are sent to the configured Erebine endpoint.")
        case ["ai", "operations"]: return CommandResult(try await runtime.operationHistory())
        case ["ai", "reset"]: return CommandResult(try await assistant.reset(sessionID))
        default: break
        }
        if parts.count == 5, parts[1] == "configure" {
            let config = AIConfiguration(baseURL: parts[2], model: parts[3], secret: parts[4]); try config.validate()
            try KilnVault.validateName(config.secret)
            try KilnStateFile.write(JSONEncoder().encode(config), to: configURL)
            return CommandResult("AI configured. Grant kiln/ai the named Vault secret. Credentials are never stored in ai.json.")
        }
        if parts.count == 4, parts[1] == "knowledge", parts[2] == "install" {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: parts[3]))
            guard bytes.count <= 32768 else { throw AIError.message("Knowledge pack exceeds 32 KiB") }
            let pack = try JSONDecoder().decode(AIKnowledgePack.self, from: bytes); try pack.validate()
            try KilnStateFile.write(JSONEncoder().encode(pack), to: knowledgeURL)
            return CommandResult("Knowledge pack \(pack.version) installed. New turns use it without a restart; permissions are unchanged.")
        }
        if parts.count == 3, parts[1] == "deny" { return CommandResult(try await assistant.deny(parts[2], session: sessionID)) }
        if parts.count == 3, parts[1] == "approve" {
            let action = try await assistant.takeApproval(parts[2], session: sessionID)
            try identities.require(principal, mutation: true, module: action.module)
            do {
                let result = try await runtime.performApprovedOperation(action.operation, name: action.module, fingerprint: action.fingerprint)
                await assistant.record(result, session: sessionID)
                return CommandResult("Executed approved operation: " + result)
            } catch {
                await assistant.record("Operation failed; inspect current state. Proposal consumed.", session: sessionID)
                throw error
            }
        }
        guard let data = try? Data(contentsOf: configURL), let configuration = try? JSONDecoder().decode(AIConfiguration.self, from: data) else {
            throw AIError.message("AI is not configured. Run ai help.")
        }
        try configuration.validate()
        let knowledge: AIKnowledgePack?
        if FileManager.default.fileExists(atPath: knowledgeURL.path) {
            knowledge = try JSONDecoder().decode(AIKnowledgePack.self, from: Data(contentsOf: knowledgeURL)); try knowledge?.validate()
        } else { knowledge = nil }
        if parts == ["ai", "status"] {
            return CommandResult("Provider: Erebine (native Swift HTTP)\nModel: \(configuration.model)\nCredential: Vault reference, granted to kiln/ai\nBuilt-in knowledge: 4\nOperator pack: \(knowledge?.version ?? "none")\nRead tools automatic; mutations require explicit proposal approval. No persisted chat history.")
        }
        guard parts.count >= 3, parts[1] == "ask" else { throw AIError.message("Use ai help") }
        let values = try runtime.vault.environment(for: "kiln/ai", bindings: ["API_KEY": configuration.secret])
        guard let key = values["API_KEY"] else { throw AIError.message("AI credential unavailable") }
        let modules = await snapshot()
        let context = "Kiln release \(KilnVersion.current)\n" + (await visibleModules())
        let text = try await assistant.ask(parts.dropFirst(2).joined(separator: " "), session: sessionID, configuration: configuration, key: key,
            modules: modules, context: context, knowledge: knowledge, progress: progress, allowProposals: !sessionID.hasPrefix("task:") && (try identities.resolve(principal).role != "viewer")) { name, module in
                try identities.require(principal, module: module.flatMap { ["module_health", "release_info", "module_resources"].contains(name) ? $0 : nil })
                switch name {
                case "create_task": try authorizeAdmin(); return try await createAITask(module!)
                case "list_tasks": try authorizeAdmin(); return try await aiTasks.list()
                case "system_status": return "Kiln \(KilnVersion.current); single node; OS process workers; opt-in bounded worker restart; cluster \(cluster == nil ? "disabled" : "enabled for explicit peer adoption and typed operations; no scheduling/failover")."
                case "list_modules": return await visibleModules()
                case "host_metrics": return await telemetry.sample().summary
                case "cluster_status": try authorizeAdmin(); return await cluster?.inventory() ?? "Cluster listener disabled"
                case "module_resources": return try await runtime.resourceStatus(module!)
                case "module_health": return try await runtime.health(module!)
                case "release_info": return try await runtime.releases(module!)
                default: throw AIError.message("Unsupported read tool")
                }
            }
        return CommandResult(text)
    }
}

private extension KilnCommands {
    func auditsMutation(_ p: [String]) -> Bool {
        guard p.count > 1 else { return false }
        switch p[0] {
        case "app": return ["install", "deploy", "start", "stop", "restart", "rollback"].contains(p[1])
        case "identity": return ["add", "set", "revoke"].contains(p[1])
        case "vault": return ["put", "grant", "revoke", "delete"].contains(p[1])
        case "key": return ["create", "delete"].contains(p[1])
        case "server": return ["add", "edit", "generate-key", "remove", "key", "trust", "exec"].contains(p[1])
        case "session": return ["new", "open", "rename", "close", "attach"].contains(p[1])
        case "ai": return ["configure", "knowledge", "approve"].contains(p[1]) || (p[1] == "concurrency" && p.count > 2) || (p[1] == "task" && p.count > 2 && ["new", "cancel", "remove"].contains(p[2]))
        case "node", "cluster": return ["accept", "revoke", "start", "stop", "restart"].contains(p[1]) || (p[1] == "adoption" && p.count > 2 && ["accept", "revoke"].contains(p[2]))
        default: return false
        }
    }
    func auditMetadata(_ p: [String]) -> (String, String?) {
        let families = ["app", "identity", "node", "cluster", "ai", "vault", "server", "key", "session", "help", "status", "metrics", "exit", "quit"]
        let actions = ["list", "help", "status", "ask", "reset", "deny", "approve", "task", "concurrency", "configure", "knowledge", "operations", "health", "logs", "releases", "resources", "start", "stop", "restart", "rollback", "install", "deploy", "add", "set", "revoke", "identity", "adoption", "receipt", "discover", "accept", "put", "grant", "grants", "delete", "edit", "generate-key", "remove", "key", "scan", "trust", "exec", "config", "create", "public", "open", "rename", "new", "attach", "close"]
        let verb = families.contains(p[0]) ? p[0] + (p.count > 1 ? " " + (actions.contains(p[1]) ? p[1] : "unknown") : "") : "unknown"
        let target = p.count > 2 && ["app", "identity", "node", "cluster"].contains(p[0]) && p[1] != "install" && p[1] != "deploy" && p[2].count <= 256 && p[2].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-/:+=".contains($0)) }) ? p[2] : nil
        return (verb, target)
    }
    func visibleModules() async -> String {
        if (try? identities.resolve(principal).role) == "admin" { return await runtime.list() }
        let modules = await snapshot()
        return modules.isEmpty ? "No visible modules." : modules.map { "\($0.id)  \($0.version)  \($0.state)  \($0.pid.map(String.init) ?? "-")" }.joined(separator: "\n")
    }
    func authorize(_ p: [String]) throws {
        try identities.require(principal)
        if p == ["help"] || p == ["status"] || p == ["metrics"] || p == ["exit"] || p == ["quit"] || p == ["app", "list"] { return }
        if p.first == "app", p.count == 3 {
            if ["health", "logs", "releases", "resources"].contains(p[1]) { try identities.require(principal, module: p[2]); return }
            if ["start", "stop", "restart", "rollback"].contains(p[1]) { try identities.require(principal, mutation: true, module: p[2]); return }
            if ["install", "deploy"].contains(p[1]) { try authorizeAdmin(); return }
        }
        if p.first == "ai" {
            if p.count == 1 || ["help", "status", "ask", "reset", "deny"].contains(p[1]) { return }
            if p[1] == "approve" { try identities.require(principal, mutation: true); return }
            if ["task", "concurrency", "configure", "knowledge", "operations"].contains(p[1]) { try authorizeAdmin(); return }
        }
        if ["identity", "vault", "server", "key", "session", "node", "cluster"].contains(p[0]) { try authorizeAdmin(); return }
        throw CommandSyntaxError.unknown
    }
    func identityCommand(_ p: [String]) throws -> CommandResult {
        switch p {
        case ["identity", "list"]: return CommandResult(try identities.list())
        case let p where p.count == 3 && p[1] == "revoke": return CommandResult(try identities.set(name: p[2], role: "viewer", key: nil, modules: [], revoke: true))
        case let p where (p.count == 5 || p.count == 6) && p[1] == "add":
            let bytes = try Data(contentsOf: URL(fileURLWithPath: p[4]))
            guard bytes.count <= 16384, let key = String(data: bytes, encoding: .utf8) else { throw KilnError.message("Invalid public key file") }
            let parsed = try NIOSSHPublicKey(openSSHPublicKey: key)
            return CommandResult(try identities.set(name: p[2], role: p[3], key: String(openSSHPublicKey: parsed), modules: p.count == 6 ? p[5].split(separator: ",").map(String.init) : []))
        case let p where (p.count == 4 || p.count == 5) && p[1] == "set": return CommandResult(try identities.set(name: p[2], role: p[3], key: nil, modules: p.count == 5 ? p[4].split(separator: ",").map(String.init) : []))
        default: return CommandResult("identity list\nidentity add <name> <admin|operator|viewer> <public-key-file> [app/module,...]\nidentity set <name> <role> [app/module,...]\nidentity revoke <name>\nEmpty scopes grant all modules. Vault, bastion, AI tasks and cluster administration require admin.")
        }
    }
}

private extension KilnCommands {
    func nodeCommand(_ input: [String], requestID: String) async throws -> CommandResult {
        var p = input
        if p.count == 4, p[1] == "adoption", ["accept", "revoke"].contains(p[2]) { p.remove(at: 1) }
        try authorizeAdmin()
        guard let cluster else { return CommandResult("Cluster listener disabled. Start Kiln with --cluster-port PORT to enable explicit peer discovery and adoption.", status: 1) }
        if p.count == 2 && p[1] == "identity" { return CommandResult("Node fingerprint: \(cluster.identity.fingerprint)\nPublic key: \(cluster.identity.publicKey)") }
        if p.count == 2 && p[1] == "list" { return CommandResult(await cluster.inventory()) }
        if p.count == 2 && p[1] == "operations" { return CommandResult(try await cluster.operations()) }
        if p.count == 4 && p[1] == "receipt" {
            let result = try await cluster.receipt(peer: p[2], requestID: p[3])
            return CommandResult("\(result.state): \(result.output)\nRequest: \(result.id)", status: result.state == "completed" ? 0 : 1)
        }
        if p.count == 3 && p[1] == "adoption" && p[2] == "list" {
            return CommandResult(await cluster.candidates().map { "\($0.fingerprint)  \($0.host):\($0.port)" }.joined(separator: "\n"))
        }
        if p.count == 4 && p[1] == "discover", let port = Int(p[3]) {
            let peer = try await cluster.discover(host: p[2], port: port)
            return CommandResult("Untrusted candidate: \(peer.fingerprint) at \(peer.host):\(peer.port). Verify fingerprint independently before node accept.")
        }
        if p.count == 3 && p[1] == "accept" { return CommandResult(try await cluster.accept(p[2])) }
        if p.count == 3 && p[1] == "revoke" { return CommandResult(try await cluster.revoke(p[2])) }
        if p.count == 3 && p[1] == "status" {
            let result = try await cluster.operate(peer: p[2], operation: .status, requestID: requestID)
            return CommandResult("\(result.state): \(result.output)\nRequest: \(result.id)" + (result.state == "completed" ? "" : "\nInspect peer state before retrying; do not blindly repeat an uncertain operation."), status: result.state == "completed" ? 0 : 1)
        }
        if p.count == 4, let operation = ClusterOperation(rawValue: p[1]), ["start", "stop", "restart"].contains(p[1]) {
            let result = try await cluster.operate(peer: p[2], operation: operation, module: p[3], requestID: requestID)
            return CommandResult("\(result.state): \(result.output)\nRequest: \(result.id)" + (result.state == "completed" ? "" : "\nInspect peer state before retrying; do not blindly repeat an uncertain operation."), status: result.state == "completed" ? 0 : 1)
        }
        return CommandResult("node identity | list | operations\nnode receipt <fingerprint> <request-id>\nnode discover <host> <port>\nnode adoption list\nnode accept <fingerprint>\nnode revoke <fingerprint>\nnode status <fingerprint>\nnode start|stop|restart <fingerprint> <app/module>\nAdoption grants administrative node operations. Both peers must explicitly trust each other.")
    }
}
