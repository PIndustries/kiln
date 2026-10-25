import Foundation
import KilnKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct WebProjectConfiguration: Codable, Sendable {
    public let schemaVersion: Int
    public let module: String
    public var source: String
    public let sdk: String
    public let publicOrigin: String
    public let ingressPort: Int
    public let workerPorts: [Int]
    public let autoPublish: Bool
}
private struct RegisteredProject: Codable {
    let configuration: WebProjectConfiguration
    let sdk: WebBuildSDK
}
private struct WebEdit: Codable { let before: String; let after: String }
private struct WebChange: Codable {
    let id: String
    let module: String
    let owner: String
    let before: String
    let after: String
    let version: String
    var status: String
    var result = ""
    var created = Date()
}
public actor WebDevelopment {
    private let directory: URL
    private var busy = Set<String>()
    private var activeJobs = Set<String>()
    public init(directory: URL) { self.directory = directory.appendingPathComponent("web-development") }
    private var projects: URL { directory.appendingPathComponent("projects") }
    private var jobs: URL { directory.appendingPathComponent("jobs") }
    private func setup() throws {
        for url in [directory, projects, jobs] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    }
    private func projectFile(_ name: String) -> URL { projects.appendingPathComponent(WebIsolation.digest(Data(name.utf8)) + ".json") }
    private func project(_ name: String) throws -> RegisteredProject {
        try setup()
        let data = try bounded(projectFile(name), limit: 1_048_576)
        let record = try JSONDecoder().decode(RegisteredProject.self, from: data)
        guard record.configuration.module == name else { throw KilnError.message("Web project unavailable") }
        return record
    }
    private func bounded(_ url: URL, limit: Int) throws -> Data {
        let metadata = try FileManager.default.attributesOfItem(atPath: url.path)
        guard metadata[.type] as? FileAttributeType == .typeRegular,
              (metadata[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              ((metadata[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o022 == 0,
              ((metadata[.size] as? NSNumber)?.intValue ?? Int.max) <= limit else { throw KilnError.message("Web project file is unsafe or oversized") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw KilnError.message("Web project file exceeded its limit") }
        return bytes
    }
    public func register(data: Data, target: ApplicationManifest) throws -> String {
        guard WebIsolation.supported, data.count <= 16384 else { throw KilnError.message("Web coding currently requires the macOS OS sandbox") }
        try setup()
        var config = try JSONDecoder().decode(WebProjectConfiguration.self, from: data)
        guard config.schemaVersion == 1, config.module == target.id, !busy.contains(config.module),
              target.ingressPort == config.ingressPort, (target.secrets ?? [:]).isEmpty,
              config.workerPorts.count == 2, Set(config.workerPorts).count == 2,
              config.workerPorts.allSatisfy({ (1024...65535).contains($0) && $0 != config.ingressPort }),
              config.publicOrigin == "http://127.0.0.1:\(config.ingressPort)",
              config.source.hasPrefix("/"), config.source.hasSuffix(".swift"), config.sdk.hasPrefix("/") else {
            throw KilnError.message("Register an exact local development module, two worker ports, one Swift source and a matching loopback origin; Vault-bound apps are excluded")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: projects.path)
        guard names.count < 8 || names.contains(projectFile(config.module).lastPathComponent) else { throw KilnError.message("Web project limit reached (8)") }
        config.source = URL(fileURLWithPath: config.source).resolvingSymlinksInPath().standardizedFileURL.path
        let bytes = try bounded(URL(fileURLWithPath: config.source), limit: 65536)
        guard String(data: bytes, encoding: .utf8) != nil else { throw KilnError.message("Web source must be UTF-8") }
        let sdk = try JSONDecoder().decode(WebBuildSDK.self, from: bounded(URL(fileURLWithPath: config.sdk), limit: 1_048_576))
        try sdk.validate(); try sdk.verifyInputs()
        try KilnStateFile.write(JSONEncoder().encode(RegisteredProject(configuration: config, sdk: sdk)), to: projectFile(config.module))
        return "Registered web source for \(config.module). Auto-publish: \(config.autoPublish). Source content can be sent to the selected AI provider. Only this source and local development release may change."
    }
    public func inventory() throws -> String {
        try setup()
        let names = try FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        return try names.prefix(8).map { url in
            let p = try JSONDecoder().decode(RegisteredProject.self, from: bounded(url, limit: 1_048_576)).configuration
            return "\(p.module) / source \(URL(fileURLWithPath: p.source).lastPathComponent) / auto-publish \(p.autoPublish) / \(p.publicOrigin)"
        }.joined(separator: "\n")
    }
    public func source(module: String, offset: Int) throws -> String {
        let config = try project(module).configuration
        let bytes = try bounded(URL(fileURLWithPath: config.source), limit: 65536)
        guard let text = String(data: bytes, encoding: .utf8), offset >= 0, offset <= text.count else { throw KilnError.message("Invalid web source offset") }
        var content = String(text.dropFirst(offset).prefix(4000))
        while true {
            let object: [String: Any] = ["module": module, "file": URL(fileURLWithPath: config.source).lastPathComponent,
                "sha256": WebIsolation.digest(bytes), "offset": offset, "nextOffset": offset + content.count,
                "complete": offset + content.count == text.count, "source": content]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            if data.count < 11000 { return String(decoding: data, as: UTF8.self) }
            content = String(content.prefix(content.count / 2))
        }
    }
    private func save(_ receipt: WebChange, at job: URL) throws { try KilnStateFile.write(JSONEncoder().encode(receipt), to: job.appendingPathComponent("receipt.json")) }
    public func changes(module: String) throws -> String {
        _ = try project(module)
        let records = try FileManager.default.contentsOfDirectory(at: jobs, includingPropertiesForKeys: nil)
        return try records.prefix(32).compactMap { folder -> String? in
            let value = try JSONDecoder().decode(WebChange.self, from: bounded(folder.appendingPathComponent("receipt.json"), limit: 16384))
            guard value.module == module else { return nil }
            let status = !activeJobs.contains(value.id) && ["building", "publishing"].contains(value.status) ? "interrupted; inspect source and release before retrying" : value.status
            return "\(value.id) / \(status) / \(value.version) / source \(value.after)\n\(value.result)"
        }.joined(separator: "\n")
    }
    public func change(module: String, owner: String, edits: String, target: ApplicationManifest,
                       progress: @escaping @Sendable (String) -> Void,
                       validate: @escaping @Sendable () throws -> Void,
                       deploy: @escaping @Sendable (String) async throws -> String) async throws -> String {
        guard WebIsolation.supported else { throw KilnError.message("Web coding currently requires macOS isolation") }
        guard !busy.contains(module), busy.count < 2 else { throw KilnError.message("A web change is already building; inspect web changes") }
        try validate(); try Task.checkCancellation()
        let registered = try project(module), config = registered.configuration
        guard config.autoPublish, target.id == module, target.ingressPort == config.ingressPort, (target.secrets ?? [:]).isEmpty else { throw KilnError.message("This module has no automatic development-publish grant") }
        let registrations = try bounded(projectFile(module), limit: 1_048_576)
        let sourceURL = URL(fileURLWithPath: config.source)
        let before = try bounded(sourceURL, limit: 65536)
        guard let text = String(data: before, encoding: .utf8), edits.utf8.count <= 4096 else { throw KilnError.message("Invalid source or edit size") }
        let replacements = try JSONDecoder().decode([WebEdit].self, from: Data(edits.utf8))
        guard !replacements.isEmpty, replacements.count <= 8 else { throw KilnError.message("Use 1–8 exact text replacements") }
        var updated = text
        for edit in replacements {
            guard !edit.before.isEmpty, edit.before != edit.after, updated.components(separatedBy: edit.before).count == 2 else { throw KilnError.message("Each before text must match exactly once in current source") }
            updated = updated.replacingOccurrences(of: edit.before, with: edit.after)
        }
        let after = Data(updated.utf8)
        guard after.count <= 65536, after != before else { throw KilnError.message("Updated source must fit 64 KiB and contain a change") }
        let entries = try FileManager.default.contentsOfDirectory(atPath: jobs.path)
        guard entries.count < 32 else { throw KilnError.message("Development artifact limit reached (32); retained active/rollback artifacts must not be removed blindly") }
        try registered.sdk.verifyInputs()
        let id = UUID().uuidString.lowercased(), version = "dev-" + UUID().uuidString.lowercased()
        let job = jobs.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var receipt = WebChange(id: id, module: module, owner: owner, before: WebIsolation.digest(before), after: WebIsolation.digest(after), version: version, status: "building")
        try save(receipt, at: job)
        try KilnStateFile.write(after, to: job.appendingPathComponent("App.swift"))
        try KilnStateFile.write(before, to: job.appendingPathComponent("Before.swift"))
        try KilnStateFile.write(JSONEncoder().encode(registered.sdk), to: job.appendingPathComponent("sdk.json"))
        busy.insert(module); activeJobs.insert(id)
        defer { busy.remove(module); activeJobs.remove(id) }
        do {
            progress("Building isolated source change for " + module)
            try await compile(sdk: registered.sdk, job: job)
            try Task.checkCancellation(); try validate(); try registered.sdk.verifyInputs()
            guard try bounded(projectFile(module), limit: 1_048_576) == registrations,
                  WebIsolation.digest(try bounded(sourceURL, limit: 65536)) == receipt.before else { throw KilnError.message("Source or registration changed during the build; prepare a fresh change") }
            let binary = job.appendingPathComponent("app")
            let binaryData = try bounded(binary, limit: 134_217_728)
            let oldPort = target.healthURL.flatMap(URL.init(string:))?.port
            guard let port = config.workerPorts.first(where: { $0 != oldPort }) else { throw KilnError.message("No alternate development worker port") }
            let libraries = String(decoding: try JSONEncoder().encode(registered.sdk.runtimeLibraries), as: UTF8.self)
            let manifest = ApplicationManifest(application: target.application, name: target.name, version: version, executable: registered.sdk.launcher,
                arguments: [binary.path, WebIsolation.digest(binaryData), libraries, "--origin", config.publicOrigin, "--development"],
                healthURL: "http://127.0.0.1:\(port)/__kiln/health", ingressPort: config.ingressPort,
                restartPolicy: target.restartPolicy, resources: target.resources)
            try manifest.validate()
            let manifestURL = job.appendingPathComponent("manifest.json")
            try KilnStateFile.write(JSONEncoder().encode(manifest), to: manifestURL)
            receipt.status = "publishing"; try save(receipt, at: job)
            progress("Publishing healthy development candidate for " + module)
            let result = try await deploy(manifestURL.path)
            receipt.status = "active-source-pending"; receipt.result = result; try save(receipt, at: job)
            try validate()
            guard WebIsolation.digest(try bounded(sourceURL, limit: 65536)) == receipt.before else { throw KilnError.message("Release is active but source changed independently; source was not overwritten") }
            try KilnStateFile.write(after, to: sourceURL)
            receipt.status = "active"; try save(receipt, at: job)
            return "Published development change \(id).\n\(result)\nSource saved: \(URL(fileURLWithPath: config.source).lastPathComponent) / SHA256 \(receipt.after)\nPreview: \(config.publicOrigin)\nDevelopment pages detect the new worker and reload. Browser delivery is separate from this server receipt."
        } catch {
            let interrupted = ["publishing", "active-source-pending"].contains(receipt.status)
            receipt.status = interrupted ? "outcome-unconfirmed" : "failed"
            receipt.result = interrupted ? "Inspect active release and source; no automatic retry or rollback was attempted." : "Build/change failed before deployment; live release and source were not changed. " + String(describing: error)
            if !interrupted, let log = try? Data(contentsOf: job.appendingPathComponent("build.log")) {
                receipt.result += "\nCompiler diagnostics:\n" + String(decoding: log.prefix(4096), as: UTF8.self)
            }
            try? save(receipt, at: job)
            throw KilnError.message("Web change \(id): \(receipt.result)")
        }
    }
    private func compile(sdk: WebBuildSDK, job: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sdk.builder); process.arguments = [job.path]
        process.currentDirectoryURL = job
        process.environment = ["HOME": job.path, "TMPDIR": job.path + "/", "PATH": "/usr/bin:/bin"]
        let log = job.appendingPathComponent("build.log")
        try KilnStateFile.write(Data(), to: log)
        let output = try FileHandle(forWritingTo: log); defer { try? output.close() }
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = output
        try process.run()
        defer { if process.isRunning { _ = kill(-process.processIdentifier, SIGKILL); _ = kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning {
            try Task.checkCancellation()
            let size = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? NSNumber)?.intValue ?? 0
            guard Date() < deadline, size <= 65536 else { throw KilnError.message("Build exceeded its time or diagnostic limit") }
            try await Task.sleep(for: .milliseconds(50))
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw KilnError.message("Isolated compiler failed") }
    }
}
private extension ApplicationManifest { var id: String { application + "/" + name } }
