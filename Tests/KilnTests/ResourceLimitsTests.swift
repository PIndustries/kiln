import Foundation
import Testing
import KilnKit
import KilnRuntime

@Test func resourceManifestPreservesLegacyAndRejectsUnsafeBounds() throws {
    let legacy = Data(#"{"application":"sample","name":"worker","version":"1","executable":"/bin/sleep","arguments":["1"]}"#.utf8)
    #expect(try JSONDecoder().decode(ApplicationManifest.self, from: legacy).resources == nil)
    let limits = ModuleResourceLimits(memoryBytes: 134_217_728, cpuMillis: 250, maxProcesses: 32)
    let manifest = ApplicationManifest(name: "worker", version: "1", executable: "/bin/sleep", resources: limits)
    try manifest.validate()
    #expect(try JSONDecoder().decode(ApplicationManifest.self, from: JSONEncoder().encode(manifest)).resources == limits)
    for invalid in [ModuleResourceLimits(memoryBytes: 1, cpuMillis: 1000, maxProcesses: 32),
                    ModuleResourceLimits(memoryBytes: 134_217_729, cpuMillis: 1000, maxProcesses: 32),
                    ModuleResourceLimits(memoryBytes: 134_217_728, cpuMillis: 0, maxProcesses: 32),
                    ModuleResourceLimits(memoryBytes: 134_217_728, cpuMillis: 1000, maxProcesses: 0)] {
        #expect(throws: (any Error).self) { try invalid.validate() }
    }
}

#if os(macOS)
@Test func macOSRefusesHardResourceManifestBeforeInstallingIt() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try KilnRuntime(stateDirectory: directory)
    let manifest = ApplicationManifest(name: "limited", version: "1", executable: "/bin/sleep", arguments: ["60"], resources: .init(memoryBytes: 134_217_728, cpuMillis: 250, maxProcesses: 32))
    let path = directory.appendingPathComponent("manifest.json")
    try JSONEncoder().encode(manifest).write(to: path)
    do {
        _ = try await runtime.install(path: path.path)
        Issue.record("macOS accepted unenforceable hard limits")
    } catch {
        #expect(String(describing: error).contains("macOS enforcement is unsupported"))
    }
    #expect(await runtime.snapshot().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("releases/default/limited").path))
    await runtime.shutdown()
}
#endif

private struct OldInstallation: Decodable {
    let manifest: ApplicationManifest
    let desiredRunning: Bool
    let previous: ApplicationManifest?
}

@Test func resourceIndexRefusesOldDecoderAndRemainsVersioned() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let index = directory.appendingPathComponent("applications.json")
    // A node already upgraded to format 2 must never silently downgrade when
    // the current desired applications no longer need hard resource controls.
    try Data(#"{"formatVersion":2,"applications":{}}"#.utf8).write(to: index)
    let runtime = try KilnRuntime(stateDirectory: directory)
    let manifest = ApplicationManifest(name: "legacy", version: "1", executable: "/bin/sleep", arguments: ["60"])
    let path = directory.appendingPathComponent("manifest.json")
    try JSONEncoder().encode(manifest).write(to: path)
    _ = try await runtime.install(path: path.path)
    let data = try Data(contentsOf: index)
    #expect(throws: (any Error).self) { _ = try JSONDecoder().decode([String: OldInstallation].self, from: data) }
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["formatVersion"] as? Int == 2)
    #expect((object["applications"] as? [String: Any])?["default/legacy"] != nil)
    let restored = try KilnRuntime(stateDirectory: directory)
    #expect(await restored.snapshot().first?.id == "default/legacy")
    await runtime.shutdown(); await restored.shutdown()
    try Data(#"{"formatVersion":99,"applications":{}}"#.utf8).write(to: index)
    #expect(throws: (any Error).self) { _ = try KilnRuntime(stateDirectory: directory) }
}

#if os(Linux)
@Test func installingResourceManifestUpgradesApplicationIndex() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try KilnRuntime(stateDirectory: directory)
    let manifest = ApplicationManifest(name: "limited", version: "1", executable: "/bin/sleep", arguments: ["60"], resources: .init(memoryBytes: 134_217_728, cpuMillis: 250, maxProcesses: 32))
    let path = directory.appendingPathComponent("manifest.json")
    try JSONEncoder().encode(manifest).write(to: path)
    _ = try await runtime.install(path: path.path)
    let data = try Data(contentsOf: directory.appendingPathComponent("applications.json"))
    #expect(throws: (any Error).self) { _ = try JSONDecoder().decode([String: OldInstallation].self, from: data) }
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["formatVersion"] as? Int == 2)
    await runtime.shutdown()
}
#endif
