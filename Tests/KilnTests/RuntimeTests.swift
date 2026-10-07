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
