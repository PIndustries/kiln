import KilnRuntime

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
    public init(runtime: KilnRuntime) { self.runtime = runtime }
    public func execute(_ line: String) async -> CommandResult {
        var parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if parts.first == "kiln" { parts.removeFirst() }
        if parts.isEmpty { return CommandResult("") }
        do {
            switch parts {
            case ["help"]:
                return CommandResult("""
                Kiln 0.1 development shell
                status                  Runtime status
                app list                Installed applications and process state
                app install <manifest>  Install a trusted local executable release
                app start <name>        Start a separate application process
                app stop <name>         Stop an application
                app restart <name>      Stop and start an application
                app health <name>       Check its configured HTTP health endpoint
                app logs <name>         Last 8 KiB of application logs
                exit                    Disconnect this session
                Paths containing spaces are not supported in this prototype shell.
                """)
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
