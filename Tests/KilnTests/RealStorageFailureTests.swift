import XCTest
import Foundation
import KilnKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class RealStorageFailureTests: XCTestCase {
    func testRealPermissionDenialPreservesCommittedState() throws {
        guard geteuid() != 0 else { throw XCTSkip("Real EACCES needs a non-root user; macOS CI exercises this case") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-eacces-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { chmod(directory.path, 0o700); try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("committed")
        let previous = Data("previous committed state".utf8)
        try KilnStateFile.write(previous, to: target)
        XCTAssertEqual(chmod(directory.path, 0o500), 0)
        let probe = open(directory.appendingPathComponent("probe").path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        let failure = errno
        if probe >= 0 { close(probe) }
        XCTAssertEqual(probe, -1, "Filesystem must actually deny creation")
        XCTAssertEqual(failure, EACCES)
        guard probe == -1, failure == EACCES else { return }
        XCTAssertThrowsError(try KilnStateFile.write(Data("replacement".utf8), to: target))
        XCTAssertEqual(try Data(contentsOf: target), previous)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["committed"])
        XCTAssertEqual(chmod(directory.path, 0o700), 0)
        try KilnStateFile.write(Data("recovered".utf8), to: target)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "recovered")
        print("KILN_REAL_EACCES_COMPLETE")
    }

    func testRealENOSPCPreservesCommittedState() throws {
        #if os(Linux)
        guard let requested = ProcessInfo.processInfo.environment["KILN_ENOSPC_MOUNT"] else {
            throw XCTSkip("Opt-in CI-owned bounded tmpfs required; real ENOSPC was not exercised")
        }
        // Refuse arbitrary paths, symlinks, shared /dev/shm and host filesystems.
        let root = URL(fileURLWithPath: requested).standardizedFileURL
        guard requested == "/kiln-enospc", root.resolvingSymlinksInPath().path == requested else {
            XCTFail("Only the dedicated /kiln-enospc mount is allowed"); return
        }
        let mounts = try String(contentsOfFile: "/proc/self/mountinfo", encoding: .utf8).split(separator: "\n")
        let matching = mounts.filter { line in
            let fields = line.split(separator: " ")
            return fields.count > 6 && fields[4] == Substring(requested)
        }
        guard matching.count == 1, matching[0].contains(" - tmpfs ") else {
            XCTFail("Dedicated tmpfs mount required before any writes"); return
        }
        var info = statvfs()
        guard statvfs(requested, &info) == 0, info.f_frsize > 0,
              info.f_blocks > 0, info.f_blocks <= 16_777_216 / info.f_frsize else {
            XCTFail("tmpfs must have a verified positive capacity no greater than 16 MiB"); return
        }
        guard try FileManager.default.contentsOfDirectory(atPath: requested).isEmpty else {
            XCTFail("Refusing a nonempty tmpfs fixture"); return
        }
        let target = root.appendingPathComponent("committed")
        let filler = root.appendingPathComponent("filler")
        defer { try? FileManager.default.removeItem(at: filler); try? FileManager.default.removeItem(at: target) }
        let previous = Data("previous committed state".utf8)
        try KilnStateFile.write(previous, to: target)
        let fd = open(filler.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { XCTFail("Cannot create bounded filler"); return }
        defer { close(fd) }
        let chunk = [UInt8](repeating: 0xA5, count: 65_536)
        var total = 0; var observedENOSPC = false
        for _ in 0..<258 {
            let count = chunk.withUnsafeBytes { Glibc.write(fd, $0.baseAddress!, $0.count) }
            if count < 0 {
                let failure = errno
                if failure == EINTR { continue }
                XCTAssertEqual(failure, ENOSPC)
                observedENOSPC = failure == ENOSPC; break
            }
            total += count
            guard count > 0, total <= 16_777_216 else { XCTFail("Bounded fill limit exceeded"); return }
        }
        guard observedENOSPC else { XCTFail("Did not observe real ENOSPC within bounded writes"); return }
        XCTAssertThrowsError(try KilnStateFile.write(Data("replacement".utf8), to: target))
        XCTAssertEqual(try Data(contentsOf: target), previous)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: requested)), ["committed", "filler"])
        // Truncate, not merely unlink: the filler descriptor is still open.
        XCTAssertEqual(ftruncate(fd, 0), 0)
        try KilnStateFile.write(Data("recovered".utf8), to: target)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "recovered")
        print("KILN_REAL_ENOSPC_COMPLETE bytes=\(total) capacity=\(info.f_blocks * info.f_frsize)")
        #else
        throw XCTSkip("Real ENOSPC fixture is Linux CI-only; no local filesystem is filled")
        #endif
    }
}
