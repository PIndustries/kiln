import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A stalled or noisy ps must not indefinitely block the shared sampler.
enum ProcessSnapshot {
    static func read(executable: String = "/bin/ps", arguments: [String] = ["-axo", "pid=,pcpu=,rss="],
                     timeout: Duration = .seconds(2), byteLimit: Int = 4 * 1024 * 1024) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        do { try process.run() } catch { return nil }
        // Only the child retains a writer; EOF must not depend on this scope ending.
        try? pipe.fileHandleForWriting.close()
        defer {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        let fd = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while ContinuousClock.now < deadline {
            let count = buffer.withUnsafeMutableBytes { bytes in
                #if canImport(Darwin)
                Darwin.read(fd, bytes.baseAddress!, bytes.count)
                #else
                Glibc.read(fd, bytes.baseAddress!, bytes.count)
                #endif
            }
            if count > 0 {
                guard count <= byteLimit - data.count else { return nil }
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                if !process.isRunning { return process.terminationStatus == 0 ? data : nil }
                // A child may close stdout and then hang. Keep the same deadline.
                Thread.sleep(forTimeInterval: 0.005)
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                Thread.sleep(forTimeInterval: 0.005)
            } else if errno != EINTR {
                return nil
            }
        }
        return nil
    }
}
