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
        let worker = Process()
        worker.executableURL = URL(fileURLWithPath: arguments[1])
        worker.arguments = Array(arguments.dropFirst(2))
        worker.environment = ProcessInfo.processInfo.environment
        worker.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        worker.standardInput = FileHandle.nullDevice
        worker.standardOutput = FileHandle.standardError
        worker.standardError = FileHandle.standardError
        // A supervisor killed before reading the acknowledgement closes stdout.
        // Never let SIGPIPE abandon a child we have already launched.
        signal(SIGPIPE, SIG_IGN)
        try launchWithWorkerSignals(worker)
        let acknowledgement = Array("\(worker.processIdentifier)\n".utf8)
        let acknowledged = acknowledgement.withUnsafeBytes { bytes in
            while true {
                #if canImport(Darwin)
                let count = Darwin.write(STDOUT_FILENO, bytes.baseAddress!, bytes.count)
                #else
                let count = Glibc.write(STDOUT_FILENO, bytes.baseAddress!, bytes.count)
                #endif
                if count < 0 && errno == EINTR { continue }
                return count == bytes.count
            }
        }
        while acknowledged && worker.isRunning && !lifetimeEnded(timeout: 100) {}
        if worker.isRunning {
            worker.terminate()
            for _ in 0..<30 {
                if !worker.isRunning { break }
                usleep(100_000)
            }
            if worker.isRunning { kill(worker.processIdentifier, SIGKILL) }
        }
        // Keep the shared lock until the exact child we created is reaped. A
        // wedged unkillable child deliberately blocks recovery instead of overlap.
        worker.waitUntilExit()
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
