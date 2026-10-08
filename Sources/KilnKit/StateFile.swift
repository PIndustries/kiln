import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Atomic replacement with explicit filesystem flushes. Storage hardware still
/// determines power-loss guarantees; errors after rename have an uncertain outcome.
public enum KilnStateFile {
    public struct CommitUncertain: Error, Sendable, CustomStringConvertible {
        public var description: String { "State was replaced but its directory flush failed; restart and reconcile before retrying" }
    }
    public static func write(_ data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".kiln-write-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw KilnError.message("Cannot create private state transaction") }
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                #if canImport(Darwin)
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                #else
                let count = Glibc.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                #endif
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw KilnError.message("Cannot write state transaction") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw KilnError.message("Cannot flush state transaction") }
        guard rename(temporary.path, destination.path) == 0 else { throw KilnError.message("Cannot commit state transaction") }
        let directory = open(parent.path, O_RDONLY | O_CLOEXEC)
        guard directory >= 0 else { throw CommitUncertain() }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw CommitUncertain() }
    }
}
