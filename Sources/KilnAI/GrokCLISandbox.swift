import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// macOS inference-only CLI worker. Uses an empty temporary home and denies
/// process forks: Grok's autonomous shell/MCP workers are intentionally unavailable.
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
        #else
        false
        #endif
    }
    public func worker(apiKey: String) -> GrokCLIWorker {
        GrokCLIWorker { request in try start(request, apiKey: apiKey) }
    }
    func start(_ request: GrokCLIRequest, apiKey: String) throws -> GrokCLIExecution {
        guard Self.supported else { throw AIError.message("Grok headless OS isolation is currently supported on macOS only") }
        guard !apiKey.isEmpty, apiKey.utf8.count <= 8192, !apiKey.contains("\0") else { throw AIError.message("Grok headless requires a Vault API credential") }
        let scratch = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("kiln-grok-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", Self.profile(executable: executable.path, scratch: scratch.path), executable.path] + request.arguments
        process.currentDirectoryURL = scratch
        process.environment = ["HOME": scratch.path, "XDG_CONFIG_HOME": scratch.path, "XDG_CACHE_HOME": scratch.path,
                               "TMPDIR": scratch.path, "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "XAI_API_KEY": apiKey]
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr
        let (stream, continuation) = AsyncThrowingStream<GrokCLIOutput, Error>.makeStream(bufferingPolicy: .bufferingOldest(32))
        let control = GrokProcessControl(process)
        do { try process.run() } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw AIError.message("Unable to start isolated Grok worker")
        }
        let readers = DispatchGroup()
        for (pipe, diagnostic) in [(stdout, false), (stderr, true)] {
            readers.enter()
            DispatchQueue.global().async {
                defer { try? pipe.fileHandleForReading.close(); readers.leave() }
                do {
                    while let data = try pipe.fileHandleForReading.read(upToCount: 4096), !data.isEmpty {
                        let result = continuation.yield(diagnostic ? .stderrBytes(data.count) : .stdout(data))
                        if case .dropped = result {
                            control.cancel(); continuation.finish(throwing: AIError.message("Grok consumer could not keep up with output")); return
                        }
                    }
                } catch { control.cancel(); continuation.finish(throwing: AIError.message("Grok output pipe failed")) }
            }
        }
        DispatchQueue.global().async {
            process.waitUntilExit()
            readers.wait()
            continuation.yield(.exited(process.terminationStatus)); continuation.finish()
            try? FileManager.default.removeItem(at: scratch)
        }
        // An independent deadline also covers a stalled stream consumer.
        DispatchQueue.global().asyncAfter(deadline: .now() + request.timeoutSeconds) { control.cancel() }
        return GrokCLIExecution(output: stream, cancel: { control.cancel() })
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
