import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Inference-only CLI worker with OS-enforced filesystem isolation.
/// macOS denies forks; Linux puts descendants in a disposable PID namespace.
public struct GrokCLISandbox: Sendable {
    public let executable: URL
    public init(executable: URL) throws {
        let resolved = executable.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.isFileURL, resolved.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: resolved.path),
              !resolved.path.contains("\n"), !resolved.path.contains("\0") else {
            throw AIError.message("Grok requires an explicit installed executable path")
        }
        self.executable = resolved
    }
    public static var supported: Bool {
        #if os(macOS)
        FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec")
        #elseif os(Linux)
        FileManager.default.isExecutableFile(atPath: "/usr/bin/bwrap")
        #else
        false
        #endif
    }
    public func worker(apiKey: String) -> GrokCLIWorker {
        GrokCLIWorker { request in try start(request, apiKey: apiKey) }
    }
    func start(_ request: GrokCLIRequest, apiKey: String) throws -> GrokCLIExecution {
        guard Self.supported else { throw AIError.message("Grok headless requires sandbox-exec on macOS or /usr/bin/bwrap with working user namespaces on Linux") }
        let credential = apiKey
        guard !credential.isEmpty, credential.utf8.count <= 8192, !credential.contains("\0") else {
            throw AIError.message("Grok headless requires a Vault API credential")
        }
        let scratch = try Self.makeHome()
        return try launch(arguments: request.arguments, timeoutSeconds: request.timeoutSeconds,
                          scratch: scratch, apiKey: apiKey, removeHomeOnExit: true)
    }
    static func makeHome() throws -> URL {
        let scratch = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("kiln-grok-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return scratch
    }
    /// Internal entry for official device login, using only a newly-created Kiln
    /// home. It never accepts an existing user home or imports configuration.
    func launch(arguments: [String], timeoutSeconds: Double, scratch: URL, apiKey: String? = nil,
                removeHomeOnExit: Bool = false, loginDiagnostics: Bool = false) throws -> GrokCLIExecution {
        guard Self.supported else { throw AIError.message("Grok OS sandbox is unavailable") }
        let process = Process()
        #if os(Linux)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bwrap")
        process.arguments = Self.linuxArguments(executable: executable.path, scratch: scratch.path) + arguments
        let childHome = "/workspace"
        #else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", Self.profile(executable: executable.path, scratch: scratch.path), executable.path] + arguments
        let childHome = scratch.path
        #endif
        process.currentDirectoryURL = scratch
        var environment = ["HOME": childHome, "XDG_CONFIG_HOME": childHome, "XDG_CACHE_HOME": childHome,
                           "TMPDIR": childHome, "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        if let apiKey { environment["XAI_API_KEY"] = apiKey }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr
        let (stream, continuation) = AsyncThrowingStream<GrokCLIOutput, Error>.makeStream(bufferingPolicy: .bufferingOldest(32))
        let control = GrokProcessControl(process)
        let completion = GrokProcessCompletion()
        do { try process.run() } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw AIError.message("Unable to start isolated Grok worker")
        }
        let readers = DispatchGroup()
        for (pipe, diagnostic) in [(stdout, false), (stderr, true)] {
            readers.enter()
            DispatchQueue.global().async {
                defer { try? pipe.fileHandleForReading.close(); readers.leave() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    // Foundation read(upToCount:) can wait for a full buffer on
                    // pipes. POSIX read returns as soon as a partial chunk arrives.
                    let count = buffer.withUnsafeMutableBytes { bytes in
                        read(pipe.fileHandleForReading.fileDescriptor, bytes.baseAddress!, bytes.count)
                    }
                    if count == 0 { return }
                    if count < 0 {
                        if errno == EINTR { continue }
                        control.cancel(); continuation.finish(throwing: AIError.message("Grok output pipe failed")); return
                    }
                    let data = Data(buffer.prefix(count))
                    let result = continuation.yield(diagnostic && !loginDiagnostics ? .stderrBytes(data.count) : .stdout(data))
                    if case .dropped = result {
                        control.cancel(); continuation.finish(throwing: AIError.message("Grok consumer could not keep up with output")); return
                    }
                }
            }
        }
        DispatchQueue.global().async {
            process.waitUntilExit()
            readers.wait()
            continuation.yield(.exited(process.terminationStatus)); continuation.finish()
            if removeHomeOnExit { try? FileManager.default.removeItem(at: scratch) }
            Task { await completion.finish() }
        }
        // An independent deadline also covers a stalled stream consumer.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) { control.cancel() }
        return GrokCLIExecution(output: stream, cancel: { control.cancel() }, waitForExit: { await completion.wait() })
    }
    /// A new mount/user/PID/IPC/UTS namespace with only the executable, runtime
    /// libraries, trust roots, DNS configuration and scratch home mounted. Network
    /// is deliberately shared for inference. Never substitute a host root bind.
    static func linuxArguments(executable: String, scratch: String) -> [String] {
        var args = ["--unshare-all", "--share-net", "--die-with-parent", "--new-session",
                    "--cap-drop", "ALL", "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp"]
        for path in ["/usr/lib", "/usr/lib64", "/lib", "/lib64", "/etc/ssl/certs",
                     "/etc/pki/tls/certs", "/etc/pki/tls/cert.pem", "/etc/pki/ca-trust",
                     "/usr/share/ca-certificates", "/etc/resolv.conf", "/etc/hosts",
                     "/etc/nsswitch.conf", "/etc/ld.so.cache"] {
            if FileManager.default.fileExists(atPath: path) { args += ["--ro-bind", path, path] }
        }
        let guestExecutable = "/kiln/" + URL(fileURLWithPath: executable).lastPathComponent
        args += ["--dir", "/kiln", "--ro-bind", executable, guestExecutable,
                 "--bind", scratch, "/workspace", "--chdir", "/workspace",
                 "--remount-ro", "/", "--", guestExecutable]
        return args
    }
    static func profile(executable: String, scratch: String) -> String {
        // Foundation preserves /var aliases on macOS; Seatbelt compares the
        // kernel's canonical /private/var path, so use POSIX realpath here.
        func canonical(_ path: String) -> String {
            guard let pointer = realpath(path, nil) else { return path }
            defer { free(pointer) }
            return String(cString: pointer)
        }
        let executable = canonical(executable), scratch = canonical(scratch)
        func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        return """
        (version 1)
        (deny default)
        (allow process-exec (literal \(quoted(executable))))
        (allow signal (target self))
        (allow sysctl-read)
        (allow file-read-metadata)
        (allow mach-lookup)
        (allow file-read* (literal "/") (subpath "/System") (subpath "/usr/lib") (subpath "/usr/share")
          (subpath "/private/var/db/dyld") (literal "/dev/null") (literal "/dev/urandom")
          (literal "/dev/random") (literal "/private/etc/resolv.conf")
          (literal "/private/etc/hosts") (literal \(quoted(executable))))
        (allow file-read* file-write* (subpath \(quoted(scratch))))
        (allow network-outbound)
        """
    }
}
private final class GrokProcessControl: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var cancelled = false
    init(_ process: Process) { self.process = process }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return }; cancelled = true
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    }
}

private actor GrokProcessCompletion {
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func finish() { finished = true; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
    func wait() async {
        if finished { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
