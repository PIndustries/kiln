import Foundation
import Testing
import KilnKit
import KilnRuntime
import KilnCommands

@Test func rejectsTraversalAndRemoteHealth() throws {
    #expect(throws: (any Error).self) {
        try ApplicationManifest(name: "../escape", version: "1", executable: "/bin/echo").validate()
    }
    #expect(throws: (any Error).self) {
        try ApplicationManifest(name: "ok", version: "1", executable: "/bin/echo", healthURL: "http://example.com/").validate()
    }
}

@Test func runtimeWorksWithoutSSHAndPreservesInstallations() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try KilnRuntime(stateDirectory: directory)
    let commands = KilnCommands(runtime: runtime)
    let unknown = await commands.execute("$(touch /tmp/should-not-execute)")
    #expect(unknown.status == 2)
    let manifest = ApplicationManifest(application: "sample", name: "worker", version: "1.0.0", executable: "/bin/sleep", arguments: ["60"])
    let path = directory.appendingPathComponent("manifest.json")
    try JSONEncoder().encode(manifest).write(to: path)
    _ = try await runtime.install(path: path.path)
    _ = try await runtime.start("sample/worker")
    #expect(await runtime.list().contains("running"))
    await runtime.shutdown()
    let restored = try KilnRuntime(stateDirectory: directory)
    try await restored.restore()
    #expect(await restored.snapshot().first?.id == "sample/worker")
    #expect(await restored.list().contains("running"))
    _ = try await restored.stop("sample/worker")
    #expect(await restored.list().contains("stopped"))
    await restored.shutdown()
}

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Test func supervisorBoundsCrashLoopsAndHonorsStop() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try KilnRuntime(stateDirectory: directory)
    let fixture = directory.appendingPathComponent("worker.sh")
    try Data("#!/bin/sh\nexec /bin/sleep 60\n".utf8).write(to: fixture)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
    let manifest = ApplicationManifest(name: "worker", version: "1", executable: fixture.path, restartPolicy: .always)
    let path = directory.appendingPathComponent("manifest.json")
    try JSONEncoder().encode(manifest).write(to: path)
    _ = try await runtime.install(path: path.path)
    _ = try await runtime.start("default/worker")
    var pid = try #require(await runtime.snapshot().first?.pid)
    for _ in 0..<3 {
        #expect(kill(pid, SIGKILL) == 0)
        var replacement: Int32?
        for _ in 0..<120 {
            try await Task.sleep(for: .milliseconds(50))
            if let next = await runtime.snapshot().first?.pid, next != pid { replacement = next; break }
        }
        pid = try #require(replacement)
    }
    #expect(kill(pid, SIGKILL) == 0)
    try await Task.sleep(for: .milliseconds(500))
    #expect(await runtime.snapshot().first?.state == "failed")
    _ = try await runtime.start("default/worker")
    #expect(await runtime.snapshot().first?.state == "running")
    _ = try await runtime.stop("default/worker")
    try await Task.sleep(for: .milliseconds(1500))
    #expect(await runtime.snapshot().first?.state == "stopped")
    await runtime.shutdown()
}

@Test func restorationContinuesAfterOneWorkerFails() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try KilnRuntime(stateDirectory: directory)
    for name in ["broken", "healthy"] {
        let manifest = ApplicationManifest(name: name, version: "1", executable: "/bin/sleep", arguments: ["60"])
        let path = directory.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: path)
        _ = try await runtime.install(path: path.path)
        _ = try await runtime.start("default/\(name)")
    }
    await runtime.shutdown()
    try FileManager.default.removeItem(at: directory.appendingPathComponent("releases/default/broken/1/app"))
    let restored = try KilnRuntime(stateDirectory: directory)
    try await restored.restore()
    #expect(await restored.snapshot().first(where: { $0.name == "broken" })?.state == "exited")
    #expect(await restored.snapshot().first(where: { $0.name == "healthy" })?.state == "running")
    await restored.shutdown()
}

@Test func legacyWorkerExitIsObservedWhenItsChildKeepsRunning() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        // These short-lived descendants deliberately have no resource policy.
        // They belong solely to this test; limited-worker tree cleanup is covered
        // by the real cgroup integration suite.
        let file = directory.appendingPathComponent("data/default/forker/children")
        if let contents = try? String(contentsOf: file, encoding: .utf8) {
            for line in contents.split(separator: "\n") {
                if let pid = Int32(line), pid > 0 { _ = kill(pid, SIGTERM) }
            }
        }
        try? FileManager.default.removeItem(at: directory)
    }
    let runtime = try KilnRuntime(stateDirectory: directory)
    let fixture = directory.appendingPathComponent("forker.sh")
    try Data("#!/bin/sh\n/bin/sleep 20 &\nprintf '%s\\n' $! >> \"$KILN_DATA_DIR/children\"\nexit 0\n".utf8).write(to: fixture)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
    let manifest = ApplicationManifest(name: "forker", version: "1", executable: fixture.path)
    let path = directory.appendingPathComponent("manifest.json")
    try JSONEncoder().encode(manifest).write(to: path)
    _ = try await runtime.install(path: path.path)
    for _ in 0..<2 {
        _ = try await runtime.start("default/forker")
        for _ in 0..<60 {
            if await runtime.snapshot().first?.state == "exited" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await runtime.snapshot().first?.state == "exited")
    }
    await runtime.shutdown()
}

@Test func workerExecFailureIsRejectedBeforeReportingStarted() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try KilnRuntime(stateDirectory: directory)
    let executable = directory.appendingPathComponent("invalid-executable")
    try Data("This file has execute permission but no executable format.\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let manifest = ApplicationManifest(name: "invalid", version: "1", executable: executable.path)
    let path = directory.appendingPathComponent("manifest.json")
    try JSONEncoder().encode(manifest).write(to: path)
    _ = try await runtime.install(path: path.path)
    var rejected = false
    do { _ = try await runtime.start("default/invalid") }
    catch { rejected = true }
    #expect(rejected)
    #expect(await runtime.snapshot().first?.state == "stopped")
    await runtime.shutdown()
}
