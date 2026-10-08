import Foundation
import KilnKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A bounded, shared tail for all generations of one module. Cooperating
/// guardians lock the same inode; append mode prevents stale inherited offsets.
enum WorkerLog {
    static let maximumBytes = 4 * 1024 * 1024
    static let retainedBytes = 2 * 1024 * 1024

    static func open(_ url: URL) throws -> FileHandle {
        let fd = url.path.withCString { path in
            #if canImport(Darwin)
            Darwin.open(path, O_CREAT | O_RDWR | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
            #else
            Glibc.open(path, O_CREAT | O_RDWR | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
            #endif
        }
        guard fd >= 0 else { throw KilnError.message("Cannot open worker log") }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            close(fd); throw KilnError.message("Worker log must be a regular file")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Logging failure drops output, never blocks worker ownership cleanup.
    static func append(_ bytes: [UInt8], to fd: Int32) {
        guard !bytes.isEmpty else { return }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { _ = flock(fd, LOCK_UN) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { return }
        let chunk = Array(bytes.suffix(maximumBytes))
        if metadata.st_size + off_t(chunk.count) > off_t(maximumBytes) {
            let keep = min(retainedBytes, max(0, maximumBytes - chunk.count), Int(metadata.st_size))
            var tail = [UInt8](repeating: 0, count: keep)
            let count = tail.withUnsafeMutableBytes { buffer in
                pread(fd, buffer.baseAddress, keep, metadata.st_size - off_t(keep))
            }
            guard count == keep, ftruncate(fd, 0) == 0 else { return }
            guard writeAll(tail, to: fd) else { return }
        }
        _ = writeAll(chunk, to: fd)
    }

    private static func writeAll(_ bytes: [UInt8], to fd: Int32) -> Bool {
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                #if canImport(Darwin)
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                #else
                let count = Glibc.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                #endif
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}
