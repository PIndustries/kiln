import Foundation
import Testing
import KilnKit
import KilnAI
import KilnRuntime
@testable import KilnDevelopment
@testable import KilnCommands

private func webDevRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return url
}
private func webDevFixture(_ root: URL, auto: Bool = true) throws -> (Data, ApplicationManifest) {
    let source = root.appendingPathComponent("App.swift"), sdk = root.appendingPathComponent("sdk.json")
    try KilnStateFile.write(Data("original heading".utf8), to: source)
    let input = root.appendingPathComponent("object")
    try KilnStateFile.write(Data("trusted object".utf8), to: input)
    let recipe: [String: Any] = ["schemaVersion":1, "compiler":"/usr/bin/false", "builder":"/usr/bin/false", "launcher":"/usr/bin/false", "arguments":[], "objects":[input.path], "readRoots":[root.path], "runtimeLibraries":[], "inputDigests":[input.path: WebIsolation.digest(try Data(contentsOf: input))]]
    try KilnStateFile.write(JSONSerialization.data(withJSONObject: recipe), to: sdk)
    let config: [String: Any] = ["schemaVersion":1, "module":"demo/web", "source":source.path, "sdk":sdk.path, "publicOrigin":"http://127.0.0.1:18085", "ingressPort":18085, "workerPorts":[18084,18086], "autoPublish":auto]
    let target = ApplicationManifest(application: "demo", name: "web", version: "1", executable: "/usr/bin/false", healthURL: "http://127.0.0.1:18084/health", ingressPort: 18085)
    return (try JSONSerialization.data(withJSONObject: config), target)
}
@Test func developmentSourceIsScopedAndFailedBuildNeverPublishesOrChangesSource() async throws {
    let root = try webDevRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (config, target) = try webDevFixture(root), dev = WebDevelopment(directory: root)
    if !WebIsolation.supported {
        await #expect(throws: (any Error).self) { _ = try await dev.register(data: config, target: target) }
        return
    }
    #expect(try await dev.register(data: config, target: target).contains("Auto-publish: true"))
    #expect(try await dev.inventory().contains("demo/web"))
    #expect(try await dev.source(module: "demo/web", offset: 0).contains("original heading"))
    await #expect(throws: (any Error).self) { _ = try await dev.source(module: "elsewhere/web", offset: 0) }
    await #expect(throws: (any Error).self) { _ = try await dev.source(module: "demo/web", offset: -1) }
    do {
        _ = try await dev.change(module: "demo/web", owner: "admin", edits: "[{\"before\":\"original\",\"after\":\"edited\"}]", target: target, progress: { _ in }, validate: {}, deploy: { _ in Issue.record("Failed build reached deployment"); return "bad" })
        Issue.record("Failed build reported success")
    } catch { #expect(String(describing: error).contains("before deployment")) }
    #expect(try String(contentsOf: root.appendingPathComponent("App.swift"), encoding: .utf8) == "original heading")
    #expect(try await dev.changes(module: "demo/web").contains("failed"))
    let restarted = WebDevelopment(directory: root)
    #expect(try await restarted.inventory().contains("demo/web"))
    #expect(try await restarted.changes(module: "demo/web").contains("failed"))
}
@Test func developmentGrantRejectsUnmatchedEditsMissingOptInAndChangedSdk() async throws {
    guard WebIsolation.supported else { return }
    let root = try webDevRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (config, target) = try webDevFixture(root), dev = WebDevelopment(directory: root)
    _ = try await dev.register(data: config, target: target)
    for edits in ["[]", "[{\"before\":\"missing\",\"after\":\"x\"}]", "[{\"before\":\"\",\"after\":\"x\"}]"] {
        await #expect(throws: (any Error).self) { _ = try await dev.change(module: "demo/web", owner: "admin", edits: edits, target: target, progress: { _ in }, validate: {}, deploy: { _ in Issue.record("Invalid edit published"); return "bad" }) }
    }
    try KilnStateFile.write(Data("different SDK".utf8), to: root.appendingPathComponent("object"))
    await #expect(throws: (any Error).self) { _ = try await dev.change(module: "demo/web", owner: "admin", edits: "[{\"before\":\"original\",\"after\":\"edited\"}]", target: target, progress: { _ in }, validate: {}, deploy: { _ in Issue.record("Changed SDK published"); return "bad" }) }
    let (disabled, _) = try webDevFixture(root, auto: false)
    _ = try await dev.register(data: disabled, target: target)
    await #expect(throws: (any Error).self) { _ = try await dev.change(module: "demo/web", owner: "admin", edits: "[{\"before\":\"original\",\"after\":\"edited\"}]", target: target, progress: { _ in }, validate: {}, deploy: { _ in Issue.record("Missing grant published"); return "bad" }) }
}
@Test func developmentToolsAreAbsentWithoutForegroundGrantAndWriteReceiptIsFinal() async throws {
    let config = AIConfiguration(baseURL: "http://127.0.0.1:11434", model: "fixture", secret: "", provider: .ollama)
    let module = ModuleSnapshot(application: "demo", name: "web", version: "1", state: "running", pid: 42)
    let noGrant = KilnAssistant { _, _, _, tools in
        #expect(!tools.contains { $0.function.name.contains("web_") })
        return AIMessage(role: "assistant", content: "read-only")
    }
    _ = try await noGrant.ask("edit", session: "x", configuration: config, key: "", modules: [module], context: "", knowledge: nil) { _, _ in "" }
    let writer = KilnAssistant { _, _, _, tools in
        #expect(tools.contains { $0.function.name == "update_web_source" })
        let args = String(decoding: try JSONEncoder().encode(["module":"demo/web", "edits":"[]"]), as: UTF8.self)
        let bytes = try JSONSerialization.data(withJSONObject: ["id":"write", "type":"function", "function":["name":"update_web_source", "arguments":args]])
        return AIMessage(role: "assistant", content: nil, tool_calls: [try JSONDecoder().decode(AIToolCall.self, from: bytes), try JSONDecoder().decode(AIToolCall.self, from: bytes)])
    }
    let receipt = try await writer.ask("edit", session: "x", configuration: config, key: "", modules: [module], context: "", knowledge: nil, webChange: { _, _ in "controller receipt" }) { _, _ in "" }
    #expect(receipt == "controller receipt")
}
