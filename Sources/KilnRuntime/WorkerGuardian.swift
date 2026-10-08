import Foundation
import KilnKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A separate, deliberately small process owns each worker. The supervisor owns
/// the only write end of its lifetime pipe; EOF is an unambiguous death signal,
/// independent of PID reuse and of how far launch/deployment registration got.
public enum KilnWorkerGuardian {
    public static func run(arguments: [String]) throws {
        guard arguments.count >= 2 else { throw KilnError.message("Invalid worker guardian invocation") }
        let state = URL(fileURLWithPath: arguments[0])
        let descriptor = open(state.appendingPathComponent("workers.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw KilnError.message("Cannot open worker ownership lock") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_SH) == 0 else { throw KilnError.message("Cannot acquire worker ownership lock") }
        // An old guardian might have been descheduled before acquiring its lock.
        // Checking EOF AFTER the lock prevents a late spawn after reconciliation.
        guard !lifetimeEnded() else { return }
        let environment = ProcessInfo.processInfo.environment
        var resource: ResourceController.Record?
        if let id = environment["KILN_RESOURCE_ID"] {
            guard let root = environment["KILN_RESOURCE_ROOT"],
                  let raw = environment["KILN_RESOURCE_MANIFEST"], let data = Data(base64Encoded: raw) else {
                throw KilnError.message("Incomplete resource guardian configuration")
            }
            let manifest = try JSONDecoder().decode(ApplicationManifest.self, from: data)
            try manifest.validate()
            resource = try ResourceController.create(id: id, root: root, state: state, manifest: manifest)
        }
        let worker = Process()
        let handshake = Pipe()
        worker.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        worker.arguments = ["worker-exec", resource?.root ?? "-", resource?.id ?? "-"] + Array(arguments.dropFirst())
        worker.environment = environment
        worker.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        worker.standardInput = FileHandle.nullDevice
        worker.standardOutput = handshake.fileHandleForWriting
        worker.standardError = FileHandle.standardError
        // A supervisor killed before reading the acknowledgement closes stdout.
        // Never let SIGPIPE abandon a child we have already launched.
        signal(SIGPIPE, SIG_IGN)
        var failure: (any Error)?
        do {
            try launchWithWorkerSignals(worker)
            try handshake.fileHandleForWriting.close()
            defer { try? handshake.fileHandleForReading.close() }
            guard readHandshake(handshake.fileHandleForReading.fileDescriptor) else {
                throw KilnError.message("Worker execution preparation was not acknowledged")
            }
            let acknowledged = writeBytes(STDOUT_FILENO, Array("\(worker.processIdentifier)\n".utf8))
            while acknowledged && worker.isRunning && !lifetimeEnded(timeout: 100) {}
        } catch { failure = error }
        if worker.isRunning {
            worker.terminate()
            for _ in 0..<30 {
                if !worker.isRunning { break }
                usleep(100_000)
            }
            if worker.isRunning { kill(worker.processIdentifier, SIGKILL) }
        }
        // Reap the exact direct child, then kill every remaining descendant in its
        // owned cgroup. A daemonized grandchild cannot outlive a limited worker.
        // Kill the cgroup before waiting: descendants must not hold an inherited
        // library termination descriptor open and delay direct-child reaping.
        if let resource { try ResourceController.finish(resource, state: state) }
        if worker.processIdentifier > 0 { worker.waitUntilExit() }
        if let failure { throw failure }
    }

    /// Internal same-binary trampoline. Application instructions cannot run until
    /// cgroup attachment is confirmed; this closes the spawn-then-migrate race.
    /// Unbounded workers use the same descriptor/signal isolation before exec.
    public static func execWorker(arguments: [String]) throws {
        guard arguments.count >= 3 else { throw KilnError.message("Invalid worker execution invocation") }
        if arguments[0] != "-" || arguments[1] != "-" {
            try ResourceController.attach(root: arguments[0], id: arguments[1])
        }
        for key in ["KILN_RESOURCE_ROOT", "KILN_RESOURCE_ID", "KILN_RESOURCE_MANIFEST"] { unsetenv(key) }
        // Retain a private close-on-exec acknowledgement descriptor. The guardian
        // accepts preparation only after its EOF confirms exec closed the handle.
        let acknowledgement = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        guard acknowledgement >= 0 else { throw KilnError.message("Cannot create worker execution acknowledgement") }
        defer { close(acknowledgement) }
        guard dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
            throw KilnError.message("Cannot initialize worker output")
        }
        // Swift's executable bootstrap may establish its own blocked mask, so
        // reset immediately before exec as well as before spawning this helper.
        var empty = sigset_t(); sigemptyset(&empty)
        guard pthread_sigmask(SIG_SETMASK, &empty, nil) == 0 else { throw KilnError.message("Cannot initialize resource worker signal mask") }
        signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL)
        let values = Array(arguments.dropFirst(2))
        var pointers = values.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        guard pointers.allSatisfy({ $0 != nil }) else { throw KilnError.message("Cannot allocate worker arguments") }
        pointers.append(nil)
        // Foundation.Process passes a termination socket to its child. If a
        // daemonized grandchild inherits it, Foundation never observes the direct
        // child's exit. Preserve only stdio across the final application exec;
        // CLOEXEC avoids closing descriptors while Swift helper threads use them.
        #if os(Linux)
        let descriptorDirectory = "/proc/self/fd"
        #else
        let descriptorDirectory = "/dev/fd"
        #endif
        for name in try FileManager.default.contentsOfDirectory(atPath: descriptorDirectory) {
            guard let descriptor = Int32(name), descriptor > STDERR_FILENO else { continue }
            let flags = fcntl(descriptor, F_GETFD)
            if flags < 0 && errno == EBADF { continue }
            guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
                throw KilnError.message("Cannot isolate worker file descriptors")
            }
        }
        guard writeBytes(acknowledgement, Array("ready\n".utf8)) else { throw KilnError.message("Worker execution acknowledgement closed") }
        _ = pointers.withUnsafeMutableBufferPointer { buffer in execv(values[0], buffer.baseAddress!) }
        // A failed exec leaves the acknowledgement FD open. Explicitly distinguish
        // that failure from the EOF produced by a successful exec.
        _ = writeBytes(acknowledgement, Array("failed\n".utf8))
        throw KilnError.message("Worker executable could not be started")
    }

    private static func readHandshake(_ descriptor: Int32) -> Bool {
        var data = [UInt8]()
        for _ in 0..<150 {
            if lifetimeEnded() { return false }
            var item = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let result = poll(&item, 1, 50)
            if result < 0 && errno == EINTR { continue }
            if result <= 0 { continue }
            var buffer = [UInt8](repeating: 0, count: 32)
            #if canImport(Darwin)
            let length = Darwin.read(descriptor, &buffer, buffer.count)
            #else
            let length = Glibc.read(descriptor, &buffer, buffer.count)
            #endif
            if length == 0 { return data == Array("ready\n".utf8) }
            if length < 0 && errno == EINTR { continue }
            if length < 0 { return false }
            data.append(contentsOf: buffer.prefix(length))
            if !Array("ready\n".utf8).starts(with: data) { return false }
        }
        return false
    }

    private static func writeBytes(_ descriptor: Int32, _ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { buffer in
            while true {
                #if canImport(Darwin)
                let count = Darwin.write(descriptor, buffer.baseAddress!, buffer.count)
                #else
                let count = Glibc.write(descriptor, buffer.baseAddress!, buffer.count)
                #endif
                if count < 0 && errno == EINTR { continue }
                return count == buffer.count
            }
        }
    }

    private static func launchWithWorkerSignals(_ worker: Process) throws {
        // The supervisor uses Dispatch signal sources and ignores SIGTERM/SIGINT.
        // Linux children can inherit a broad Swift/Dispatch blocked mask, also
        // breaking application HUP/USR handlers and subprocess notifications.
        // An exec'd application starts with an empty mask and ordinary termination
        // dispositions. Restore the guardian's own policy immediately after spawn.
        var emptyMask = sigset_t(), previousMask = sigset_t()
        sigemptyset(&emptyMask)
        guard pthread_sigmask(SIG_SETMASK, &emptyMask, &previousMask) == 0 else {
            throw KilnError.message("Cannot initialize worker signal mask")
        }
        let previousTerm = signal(SIGTERM, SIG_DFL)
        let previousInterrupt = signal(SIGINT, SIG_DFL)
        defer {
            _ = signal(SIGTERM, previousTerm)
            _ = signal(SIGINT, previousInterrupt)
            _ = pthread_sigmask(SIG_SETMASK, &previousMask, nil)
        }
        try worker.run()
    }

    private static func lifetimeEnded(timeout: Int32 = 0) -> Bool {
        var item = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        let result = poll(&item, 1, timeout)
        if result < 0 { return errno != EINTR }
        if result == 0 { return false }
        // This pipe carries no data: EOF or any unexpected input closes ownership.
        return item.revents != 0
    }

    /// Called before listeners/restore. Guardians never retain runtime.lock;
    /// workers.lock instead ensures all prior children have actually exited.
    public static func reconcile(directory: URL) throws {
        let descriptor = open(directory.appendingPathComponent("workers.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw KilnError.message("Cannot open worker ownership lock") }
        defer { close(descriptor) }
        for _ in 0..<200 {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return }
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw KilnError.message("Cannot reconcile worker ownership") }
            usleep(50_000)
        }
        throw KilnError.message("Previous workers have not exited; refusing to start duplicate workers. Retry after investigating worker guardians.")
    }
}
