import Foundation
import Testing
@testable import KilnRuntime
import KilnKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Test func workerLogCapsDiskAndPreservesNewestGenerationOutput() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("worker.log")
    let old = try WorkerLog.open(path), candidate = try WorkerLog.open(path)
    defer { try? old.close(); try? candidate.close() }
    let block = [UInt8](repeating: 65, count: 65536)
    for index in 0..<256 {
        WorkerLog.append(block, to: index.isMultiple(of: 2) ? old.fileDescriptor : candidate.fileDescriptor)
        let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        #expect(size <= WorkerLog.maximumBytes)
    }
    WorkerLog.append(Array("old-generation-tail\n".utf8), to: old.fileDescriptor)
    WorkerLog.append(Array("new-generation-tail\n".utf8), to: candidate.fileDescriptor)
    let data = try Data(contentsOf: path)
    #expect(data.suffix("old-generation-tail\nnew-generation-tail\n".utf8.count) == Data("old-generation-tail\nnew-generation-tail\n".utf8))
}

@Test func workerLogRejectsSymbolicLinkWithoutTouchingTarget() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("target")
    try Data("preserve".utf8).write(to: target)
    let link = root.appendingPathComponent("worker.log")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: (any Error).self) { _ = try WorkerLog.open(link) }
    #expect(try String(contentsOf: target, encoding: .utf8) == "preserve")
}

@Test func unavailableResourceDiagnosticDoesNotBlockCleanup() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("obstruction".utf8).write(to: root.appendingPathComponent("resource-reports"))
    ResourceController.writeDiagnostic("finished", module: "test/worker", state: root)
    #expect(try String(contentsOf: root.appendingPathComponent("resource-reports"), encoding: .utf8) == "obstruction")
}

@Test func floodingWorkerLogsStayBoundedAndStopWithoutWaitingForOutputEOF() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try KilnRuntime(stateDirectory: root)
    // The detached descendant retains stdout, while the direct worker exits.
    // This must not keep the guardian alive, even after enough output to rotate.
    // A copied macOS platform /bin/sh is killed by the OS before execution.
    // Install a script so its interpreter stays at the system-authorized path.
    let fixture = root.appendingPathComponent("flood.sh")
    try Data("#!/bin/sh\nhead -c 16777216 /dev/zero; printf 'FINAL-OUTPUT'; sleep 2 & exit 0\n".utf8).write(to: fixture)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
    let manifest = ApplicationManifest(name: "flood", version: "1", executable: fixture.path)
    let path = root.appendingPathComponent("manifest.json")
    try JSONEncoder().encode(manifest).write(to: path)
    _ = try await runtime.install(path: path.path)
    _ = try await runtime.start("default/flood")
    var finished = false
    for _ in 0..<100 {
        if await runtime.snapshot().first?.state == "exited" { finished = true; break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(finished)
    let output = try await runtime.logs("default/flood")
    #expect(output.utf8.count <= 8192)
    #expect(output.hasSuffix("FINAL-OUTPUT"))
    let size = try root.appendingPathComponent("logs/default/flood.log").resourceValues(forKeys: [.fileSizeKey]).fileSize!
    #expect(size <= WorkerLog.maximumBytes)
    _ = try await runtime.stop("default/flood")
    await runtime.shutdown()
}

@Test func workerLogContentionDropsOutputWithoutWaiting() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("worker.log")
    let owner = try WorkerLog.open(path), contender = try WorkerLog.open(path)
    defer { try? owner.close(); try? contender.close() }
    #expect(flock(owner.fileDescriptor, LOCK_EX | LOCK_NB) == 0)
    defer { _ = flock(owner.fileDescriptor, LOCK_UN) }
    WorkerLog.append(Array("must-drop".utf8), to: contender.fileDescriptor)
    #expect(try Data(contentsOf: path).isEmpty)
}
