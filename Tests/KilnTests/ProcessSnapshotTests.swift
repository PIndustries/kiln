import Foundation
import Testing
@testable import KilnTelemetry
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Test func processSnapshotRequiresSuccessfulExitAndKeepsCompleteOutput() {
    let result = ProcessSnapshot.read(executable: "/bin/sh", arguments: ["-c", "printf '1 2.5 16\\n'"], byteLimit: 9)
    #expect(result == Data("1 2.5 16\n".utf8))
    #expect(ProcessSnapshot.read(executable: "/bin/sh", arguments: ["-c", "printf partial; exit 1"]) == nil)
    #expect(ProcessSnapshot.read(executable: "/nonexistent/kiln-ps") == nil)
    #expect(ProcessSnapshot.read(executable: "/bin/sh", arguments: ["-c", "printf '1234567890'"], byteLimit: 9) == nil)
}

private func rejectedCollector(_ script: String, limit: Int = 1024) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("collector.pid")
    let clock = ContinuousClock()
    let start = clock.now
    let result = ProcessSnapshot.read(executable: "/bin/sh", arguments: ["-c", "printf '%s' \"$$\" > \"$1\"; " + script, "fixture", pidFile.path], timeout: .milliseconds(300), byteLimit: limit)
    #expect(result == nil)
    #expect(start.duration(to: clock.now) < .seconds(5))
    let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
    #expect(kill(pid, 0) == -1 && errno == ESRCH, "Collector must be killed and reaped before return")
}

@Test func stalledProcessCollectorIsKilledAndReaped() throws {
    // No child processes; ignore SIGTERM to verify forcible deadline cleanup.
    try rejectedCollector("trap '' TERM; while :; do :; done")
}

@Test func closedOutputDoesNotBypassProcessCollectorDeadline() throws {
    try rejectedCollector("exec 1>&-; trap '' TERM; while :; do :; done")
}

@Test func floodingProcessCollectorIsBoundedAndReaped() throws {
    try rejectedCollector("while :; do printf '12345678901234567890123456789012'; done")
}
