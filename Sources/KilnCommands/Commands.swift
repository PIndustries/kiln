import KilnRuntime
import KilnKit
import KilnTelemetry
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
    private let telemetry: KilnTelemetry
    public init(runtime: KilnRuntime) { self.runtime = runtime; self.telemetry = KilnTelemetry(diskPath: runtime.stateDirectory.path) }
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
