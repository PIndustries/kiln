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
