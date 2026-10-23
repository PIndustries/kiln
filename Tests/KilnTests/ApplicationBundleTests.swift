import Foundation
import Crypto
import Testing
import KilnKit
import KilnRuntime

private func bundleDigest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
private func bundleFixture(_ directory: URL) throws -> ApplicationBundleManifest {
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("assets"), withIntermediateDirectories: true)
    let program = Data("#!/bin/sh\nexit 0\n".utf8), asset = Data("bundle asset".utf8)
    try program.write(to: directory.appendingPathComponent("bin/worker"))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.appendingPathComponent("bin/worker").path)
    try asset.write(to: directory.appendingPathComponent("assets/message"))
    let bundle = ApplicationBundleManifest(platform: ApplicationBundleManifest.hostPlatform,
        module: ApplicationManifest(application: "bundle", name: "worker", version: "1", executable: "bin/worker"),
        files: [.init(path: "bin/worker", sha256: bundleDigest(program), executable: true), .init(path: "assets/message", sha256: bundleDigest(asset))])
    try JSONEncoder().encode(bundle).write(to: directory.appendingPathComponent("bundle.json"))
    return bundle
}

@Test func bundleRejectsTraversalCaseAliasesPrefixConflictsAndInvalidEntrypoints() throws {
    let digest = String(repeating: "a", count: 64)
    func manifest(_ paths: [String], entry: String = "bin/worker") -> ApplicationBundleManifest {
        ApplicationBundleManifest(platform: ApplicationBundleManifest.hostPlatform,
            module: ApplicationManifest(name: "worker", version: "1", executable: entry),
            files: paths.map { .init(path: $0, sha256: digest, executable: $0 == entry) })
    }
    for bad in ["../secret", "/tmp/worker", "bin//worker", "bin/./worker", "bin/../worker", "bin\\worker", "bundle.json", "bundle.json/file"] {
        #expect(throws: (any Error).self) { try manifest([bad], entry: bad).validate() }
    }
    for paths in [["bin/worker", "bin/worker"], ["bin/worker", "BIN/asset"], ["bin/worker", "bin"], ["bin/worker", "Bundle.JSON/asset"]] {
        #expect(throws: (any Error).self) { try manifest(paths).validate() }
    }
    #expect(throws: (any Error).self) { try manifest(["asset"]).validate() }
    #expect(throws: (any Error).self) { try manifest(["bin/worker"]).validate(forPlatform: "other-host") }
    let encoded = try JSONEncoder().encode(manifest(["bin/worker"]))
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["formatVersion"] = 99
    let future = try JSONDecoder().decode(ApplicationBundleManifest.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(throws: (any Error).self) { try future.validate() }
}

@Test func bundleInstallCopiesDeclaredFilesAndPersistsVersionedIntegrityMetadata() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source with spaces"), state = directory.appendingPathComponent("state with spaces")
    _ = try bundleFixture(source)
    // A transport may drop source mode bits. The declared executable flag is
    // restored on the verified copy, independently of its source permissions.
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: source.appendingPathComponent("bin/worker").path)
    try Data("do not copy".utf8).write(to: source.appendingPathComponent("undeclared"))
    let runtime = try KilnRuntime(stateDirectory: state)
    _ = try await runtime.install(path: source.path)
    try FileManager.default.removeItem(at: source)
    let release = state.appendingPathComponent("releases/bundle/worker/1")
    #expect(try String(contentsOf: release.appendingPathComponent("assets/message"), encoding: .utf8) == "bundle asset")
    #expect(!FileManager.default.fileExists(atPath: release.appendingPathComponent("undeclared").path))
    #expect(FileManager.default.isExecutableFile(atPath: release.appendingPathComponent("bin/worker").path))
    let index = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: state.appendingPathComponent("applications.json"))) as? [String: Any])
    #expect(index["formatVersion"] as? Int == 3)
    #expect(try await runtime.releases("bundle/worker").contains("Bundle: " + ApplicationBundleManifest.hostPlatform))
    await runtime.shutdown()
    let restored = try KilnRuntime(stateDirectory: state)
    // Installed assets are checked again before any worker is launched.
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: release.appendingPathComponent("assets/message").path)
    try Data("tampered".utf8).write(to: release.appendingPathComponent("assets/message"))
    await #expect(throws: (any Error).self) { _ = try await restored.start("bundle/worker") }
    #expect(await restored.snapshot().first?.pid == nil)
    await restored.shutdown()
}

@Test func corruptAndSymlinkBundlesCannotLeaveAnInstalledOrPartialRelease() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source"), state = directory.appendingPathComponent("state")
    _ = try bundleFixture(source)
    let runtime = try KilnRuntime(stateDirectory: state)
    let asset = source.appendingPathComponent("assets/message")
    try Data("wrong digest".utf8).write(to: asset)
    await #expect(throws: (any Error).self) { _ = try await runtime.install(path: source.path) }
    #expect(await runtime.snapshot().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: state.appendingPathComponent("releases/bundle/worker/1").path))
    try FileManager.default.removeItem(at: asset)
    let outside = directory.appendingPathComponent("outside"); try Data("bundle asset".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: asset, withDestinationURL: outside)
    await #expect(throws: (any Error).self) { _ = try await runtime.install(path: source.path) }
    #expect(await runtime.snapshot().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: state.appendingPathComponent("releases/bundle/worker/1").path))
    await runtime.shutdown()
}

@Test func bundleAdmissionRejectsUnknownSemanticsAndOversizeRegularFiles() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source"), state = directory.appendingPathComponent("state")
    _ = try bundleFixture(source)
    let file = source.appendingPathComponent("bundle.json"), original = try Data(contentsOf: file)
    var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
    object["installHook"] = "unsupported"
    try JSONSerialization.data(withJSONObject: object).write(to: file)
    let runtime = try KilnRuntime(stateDirectory: state)
    await #expect(throws: (any Error).self) { _ = try await runtime.install(path: source.path) }
    try original.write(to: file)
    let asset = try FileHandle(forWritingTo: source.appendingPathComponent("assets/message"))
    try asset.truncate(atOffset: 268_435_457); try asset.close()
    await #expect(throws: (any Error).self) { _ = try await runtime.install(path: source.path) }
    #expect(await runtime.snapshot().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: state.appendingPathComponent("releases/bundle/worker/1").path))
    await runtime.shutdown()
}
