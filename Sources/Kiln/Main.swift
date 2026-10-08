import Foundation
// Linux Dispatch lacks Sendable annotations; signal-source cancellation is thread-safe.
@preconcurrency import Dispatch
import KilnRuntime
import KilnKit
import KilnVault
import KilnCommands
import KilnSSH
import KilnBastion
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
        if args.first == "worker-guardian" {
            try KilnWorkerGuardian.run(arguments: Array(args.dropFirst()))
            return
        }
        if args.count == 5, args[0] == "vault", args[1] == "put", args[3] == "--state" {
            guard isatty(STDIN_FILENO) == 0 else { throw CLIError.invalid("Use the SSH dashboard for hidden entry, or redirect a secret file to stdin") }
            var data = Data()
            while let part = try FileHandle.standardInput.read(upToCount: 4096), !part.isEmpty {
                data.append(part)
                guard data.count <= 16384 else { throw CLIError.invalid("Secret exceeds 16 KiB") }
            }
            if data.last == 10 { data.removeLast(); if data.last == 13 { data.removeLast() } }
            guard let value = String(data: data, encoding: .utf8) else { throw CLIError.invalid("Secret must be UTF-8") }
            print(try KilnVault(directory: URL(fileURLWithPath: args[4]).standardizedFileURL).put(args[2], value: value))
            return
        }
        if args.count == 6, Array(args.prefix(2)) == ["vault", "init"], args[2] == "--state", args[4] == "--key-file" {
            print(try KilnVault(directory: URL(fileURLWithPath: args[3]).standardizedFileURL).initialize(keyFile: URL(fileURLWithPath: args[5])))
            return
        }
        if args == ["--version"] { print(KilnVersion.current); return }
        if args.count == 3, args[1] == "--state", ["session-service", "session-service-stop"].contains(args[0]) {
            let directory = URL(fileURLWithPath:args[2]).standardizedFileURL
            if args[0] == "session-service" { try await SessionService.run(directory:directory) }
            else { print(try await BastionClient(directory:directory).stop()) }
            return
        }
        if args.contains("--help") || args.isEmpty {
            print("""
            Kiln \(KilnVersion.current) development runtime
            kiln up [--state PATH] [--authorized-keys PATH] [--host 127.0.0.1] [--port 2222]
                    [--user admin] [--no-ssh] [--console]
            kiln vault put NAME --state PATH < secret-file   Import without command-line values
            kiln vault init --state PATH --key-file PATH   Initialize encrypted server Vault
            kiln session-service-stop --state PATH   End persistent remote terminals
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
        let lockFD = open(state.appendingPathComponent("runtime.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw CLIError.invalid("State directory already in use or cannot be locked") }
        defer { close(lockFD) }
        // Buffer shutdown requests before any service can become externally reachable.
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let signals = AsyncStream<Void> { continuation in
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            interrupt.setEventHandler { continuation.yield(()); continuation.finish() }
            terminate.setEventHandler { continuation.yield(()); continuation.finish() }
            continuation.onTermination = { _ in interrupt.cancel(); terminate.cancel() }
            interrupt.resume(); terminate.resume()
        }
        let runtime = try KilnRuntime(stateDirectory: state)
        let commands = KilnCommands(runtime: runtime)
        // Complete ownership recovery before exposing any management mutations.
        try await runtime.restore()
        try await commands.startSessionService()
        var ssh: KilnSSHServer?
        do {
            if !flags.contains("--no-ssh") {
                guard let keyPath = values["--authorized-keys"] else { throw CLIError.invalid("Provide --authorized-keys PATH, or --no-ssh") }
                guard let port = Int(values["--port"] ?? "2222"), (1...65535).contains(port) else { throw CLIError.invalid("Invalid port") }
                let host = values["--host"] ?? "127.0.0.1"
                ssh = try await KilnSSHServer.start(host: host, port: port, username: values["--user"] ?? "admin", authorizedKeys: URL(fileURLWithPath: keyPath), stateDirectory: state, commands: commands)
                print("KilnSSH enabled at \(host):\(port)")
            } else { print("KilnSSH disabled") }
        } catch { await ssh?.stop(); await runtime.shutdown(); throw error }
        print("Kiln runtime ready. State: \(state.path)")
        fflush(nil)
        let console = flags.contains("--console") ? ConsoleInput() : nil
        let consoleTask: Task<Void, Never>? = console.map { input in
            Task {
                for await line in input.lines {
                    guard !Task.isCancelled else { break }
                    let result = await commands.execute(line)
                    print(result.text); fflush(nil)
                    if result.disconnect { break }
                }
            }
        }
        for await _ in signals { break }
        consoleTask?.cancel(); console?.stop()
        print("Kiln shutting down")
        await runtime.shutdown()
        await ssh?.stop()
    }
    enum CLIError: Error { case invalid(String) }
}

/// Nonblocking stdin avoids holding a libc readLine lock through process shutdown.
/// Buffer state is confined to this source's serial queue; cancellation is thread-safe.
private final class ConsoleInput: @unchecked Sendable {
    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let source: DispatchSourceRead
    private var pending: [UInt8] = []
    private var discarding = false
    init() {
        let pair = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(16))
        lines = pair.stream; continuation = pair.continuation
        let flags = fcntl(STDIN_FILENO, F_GETFL)
        _ = fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: DispatchQueue(label: "kiln.console"))
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
    }
    private func readAvailable() {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = read(STDIN_FILENO, &bytes, bytes.count)
        if count == 0 {
            if !pending.isEmpty && !discarding { continuation.yield(String(decoding: pending, as: UTF8.self)) }
            stop(); return
        }
        guard count > 0 else { if errno != EAGAIN && errno != EINTR { stop() }; return }
        for byte in bytes.prefix(count) {
            if byte == 10 {
                if !discarding {
                    if pending.last == 13 { pending.removeLast() }
                    continuation.yield(String(decoding: pending, as: UTF8.self))
                }
                pending.removeAll(keepingCapacity: true); discarding = false
            } else if !discarding {
                if pending.count < 4096 { pending.append(byte) }
                else { pending.removeAll(keepingCapacity: true); discarding = true }
            }
        }
    }
    func stop() { source.cancel(); continuation.finish() }
    deinit { source.cancel(); continuation.finish() }
}
