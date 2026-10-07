import Foundation
import Dispatch
import KilnRuntime
import KilnCommands
import KilnSSH
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct Kiln {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("kiln: \(error)\n".utf8)); exit(1) }
    }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") || args.isEmpty {
            print("""
            Kiln 0.1 development runtime
            kiln up [--state PATH] [--authorized-keys PATH] [--host 127.0.0.1] [--port 2222]
                    [--user admin] [--no-ssh] [--console]
            --console enables the same command engine on local stdin.
            SSH is optional. --no-ssh never reads keys or opens an SSH listener.
            """); return
        }
        guard args.first == "up" else { throw CLIError.invalid("Expected: kiln up") }
        let valueFlags: Set<String> = ["--state", "--authorized-keys", "--host", "--port", "--user"]
        let booleanFlags: Set<String> = ["--no-ssh", "--console"]
        var values: [String: String] = [:]; var flags: Set<String> = []
        var index = 1
        while index < args.count {
            let flag = args[index]
            if booleanFlags.contains(flag) { flags.insert(flag); index += 1 }
            else if valueFlags.contains(flag), index + 1 < args.count { values[flag] = args[index + 1]; index += 2 }
            else { throw CLIError.invalid("Unknown option or missing value: \(flag)") }
        }
        let state = URL(fileURLWithPath: values["--state"] ?? ".kiln", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockFD = open(state.appendingPathComponent("runtime.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw CLIError.invalid("State directory already in use or cannot be locked") }
        defer { close(lockFD) }
        let runtime = try KilnRuntime(stateDirectory: state)
        let commands = KilnCommands(runtime: runtime)
        var ssh: KilnSSHServer?
        do {
            if !flags.contains("--no-ssh") {
                guard let keyPath = values["--authorized-keys"] else { throw CLIError.invalid("Provide --authorized-keys PATH, or --no-ssh") }
                guard let port = Int(values["--port"] ?? "2222"), (1...65535).contains(port) else { throw CLIError.invalid("Invalid port") }
                let host = values["--host"] ?? "127.0.0.1"
                ssh = try await KilnSSHServer.start(host: host, port: port, username: values["--user"] ?? "admin", authorizedKeys: URL(fileURLWithPath: keyPath), stateDirectory: state, commands: commands)
                print("KilnSSH enabled at \(host):\(port)")
            } else { print("KilnSSH disabled") }
            try await runtime.restore()
        } catch { await ssh?.stop(); await runtime.shutdown(); throw error }
        print("Kiln runtime ready. State: \(state.path)")
        fflush(stdout)
        if flags.contains("--console") {
            Task.detached {
                while let line = readLine() {
                    let result = await commands.execute(line)
                    print(result.text); fflush(stdout)
                    if result.disconnect { break }
                }
            }
        }
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let signals = AsyncStream<Void> { continuation in
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            interrupt.setEventHandler { continuation.yield(()); continuation.finish() }
            terminate.setEventHandler { continuation.yield(()); continuation.finish() }
            continuation.onTermination = { _ in interrupt.cancel(); terminate.cancel() }
            interrupt.resume(); terminate.resume()
        }
        for await _ in signals { break }
        print("Kiln shutting down")
        await runtime.shutdown()
        await ssh?.stop()
    }
    enum CLIError: Error { case invalid(String) }
}
