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
    public var root: String? = nil
}
struct RegisteredProject: Codable {
    let configuration: WebProjectConfiguration
    let sdk: WebBuildSDK
}
private struct WebChange: Codable {
    let id: String
    let module: String
    let owner: String
    let before: String
    let after: String
    let version: String
    var status: String
    var previousVersion: String? = nil
    var result = ""
    var created = Date()
}
public actor WebDevelopment {
    let directory: URL
    private var busy = Set<String>()
    private var activeJobs = Set<String>()
    var ideRequests = 0
    public init(directory: URL) { self.directory = directory.appendingPathComponent("web-development") }
    private var projects: URL { directory.appendingPathComponent("projects") }
    private var jobs: URL { directory.appendingPathComponent("jobs") }
    private func setup() throws {
        for url in [directory, projects, jobs] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    }
    private func projectFile(_ name: String) -> URL { projects.appendingPathComponent(WebIsolation.digest(Data(name.utf8)) + ".json") }
    func project(_ name: String) throws -> RegisteredProject {
        try setup()
        let data = try bounded(projectFile(name), limit: 1_048_576)
        let record = try JSONDecoder().decode(RegisteredProject.self, from: data)
        guard record.configuration.module == name else { throw KilnError.message("Web project unavailable") }
        return record
    }
    private func bounded(_ url: URL, limit: Int) throws -> Data { try WebFiles.readFile(url, limit: limit) }
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
        config.source = WebIsolation.canonical(config.source)
        let bytes = try bounded(URL(fileURLWithPath: config.source), limit: 65536)
        guard String(data: bytes, encoding: .utf8) != nil else { throw KilnError.message("Web source must be UTF-8") }
        if let root = config.root {
            let canonical = WebIsolation.canonical(root)
            guard root.hasPrefix("/"), root == canonical, config.source == canonical + "/App.swift" else { throw KilnError.message("Register a canonical dedicated project root with App.swift as its entry point") }
            try WebFiles.checkDirectory(URL(fileURLWithPath: root).deletingLastPathComponent())
            _ = try WebFiles.read(config)
        }
        let sdk = try JSONDecoder().decode(WebBuildSDK.self, from: bounded(URL(fileURLWithPath: config.sdk), limit: 1_048_576))
        try sdk.validate(); try sdk.verifyInputs()
        guard config.root == nil || sdk.projectFiles == true else { throw KilnError.message("Export a project-capable SDK before registering a project root") }
        try KilnStateFile.write(JSONEncoder().encode(RegisteredProject(configuration: config, sdk: sdk)), to: projectFile(config.module))
        return "Registered web source for \(config.module). Auto-publish: \(config.autoPublish). Source content can be sent to the selected AI provider. Only registered project files and the local development release may change."
    }
    func previewOrigin(module: String) throws -> String { try project(module).configuration.publicOrigin }
    public func inventory() throws -> String {
        try setup()
        let names = try FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        return try names.prefix(8).map { url in
            let p = try JSONDecoder().decode(RegisteredProject.self, from: bounded(url, limit: 1_048_576)).configuration
            return "\(p.module) / source \(URL(fileURLWithPath: p.source).lastPathComponent) / files \(p.root == nil ? "single" : "project") / auto-publish \(p.autoPublish) / \(p.publicOrigin) / Swift views: \(try project(p.module).sdk.nativeViews == true) / HTML templates: \(try project(p.module).sdk.htmlTemplates == true)"
        }.joined(separator: "\n")
    }
    private func snapshot(module: String, change: String? = nil) throws -> (WebFiles, String) {
        if let change {
            let (folder, record) = try retained(module, id: change)
            let files = try WebFiles.retained(at: folder)
            guard try files.digest == record.after else { throw KilnError.message("Retained source integrity failed") }
            return (files, record.version)
        }
        return (try WebFiles.read(project(module).configuration), "workspace")
    }
    public func tree(module: String, change: String? = nil) throws -> String {
        let (snapshot, version) = try snapshot(module: module, change: change)
        let rows: [[String:Any]] = snapshot.files.keys.sorted().map { ["path":$0,"bytes":snapshot.files[$0]!.count,"sha256":WebIsolation.digest(snapshot.files[$0]!)] }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["version":version,"editable":change == nil && project(module).configuration.autoPublish,"projectRoot":project(module).configuration.root != nil,"files":rows], options: [.sortedKeys]), as: UTF8.self)
    }
    public func file(module: String, path: String, change: String? = nil, offset: Int? = nil) throws -> String {
        guard WebFiles.validPath(path) else { throw KilnError.message("Invalid project file path") }
        let (snapshot, version) = try snapshot(module: module, change: change)
        guard let bytes = snapshot.files[path], let text = String(data: bytes, encoding: .utf8) else { throw KilnError.message("Unknown project file") }
        let start = offset ?? 0
        guard start >= 0, start <= text.count else { throw KilnError.message("Invalid source offset") }
        var content = offset == nil ? text : String(text.dropFirst(start).prefix(4000))
        while true {
            let object: [String: Any] = ["module":module,"file":path,"sha256":WebIsolation.digest(bytes),"version":version,
                "offset":start,"nextOffset":start+content.count,"complete":start+content.count == text.count,"source":content]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            if offset == nil || data.count < 11000 { return String(decoding: data, as: UTF8.self) }
            content = String(content.prefix(content.count / 2))
        }
    }
    /// Proposed source for the IDE only. Uses the exact edit/hash/path checks of
    /// publication, without changing disk or the running release.
    public func previewEdits(module: String, edits: String, limit: Int) throws -> [AISourcePreview] {
        let registered = try project(module), before = try WebFiles.read(registered.configuration)
        let after = try before.applying(edits,multiFile:registered.configuration.root != nil,limit:limit)
        return Set(before.files.keys).union(after.files.keys).sorted().compactMap { path in
            guard before.files[path] != after.files[path] else { return nil }
            return AISourcePreview(module:module,path:path,source:after.files[path].flatMap { String(data:$0,encoding:.utf8) } ?? "// Proposed deletion",draft:true)
        }
    }
    public func browse(module: String, path: String = "App.swift", change: String? = nil) throws -> String {
        let tree = try tree(module: module, change: change), file = try file(module: module, path: path, change: change)
        return "{\"tree\":" + tree + ",\"file\":" + file + "}"
    }
    public func refactor(module: String, path: String, sha256: String, style: String) throws -> WebRefactor {
        let registered = try project(module), config = registered.configuration
        guard config.root != nil, config.autoPublish, registered.sdk.projectFiles == true,
              !busy.contains(module), ["components", "functions"].contains(style), WebFiles.validPath(path), path.hasSuffix(".swift"),
              let bytes = try WebFiles.read(config).files[path], WebIsolation.digest(bytes) == sha256 else {
            throw KilnError.message("Refactor needs a current Swift file in an opted-in project root; reload the file if it changed")
        }
        return WebRefactor(module: module, path: path, sha256: sha256, style: style, registrationSHA256: WebIsolation.digest(try bounded(projectFile(module), limit: 1_048_576)))
    }
    public func verifyRefactor(_ request: WebRefactor, module: String) throws {
        guard module == request.module,
              WebIsolation.digest(try bounded(projectFile(module), limit: 1_048_576)) == request.registrationSHA256 else { throw KilnError.message("Refactor project or registration changed") }
        _ = try refactor(module: module, path: request.path, sha256: request.sha256, style: request.style)
    }
    public func source(module: String, offset: Int) throws -> String { try file(module: module, path: "App.swift", offset: offset) }
    public func isRegistered(_ module: String) -> Bool { FileManager.default.fileExists(atPath: projectFile(module).path) }
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
    private func records(_ module: String) throws -> [(URL, WebChange)] {
        _ = try project(module)
        return try FileManager.default.contentsOfDirectory(at: jobs, includingPropertiesForKeys: nil).prefix(32).compactMap { folder in
            let record = try JSONDecoder().decode(WebChange.self, from: bounded(folder.appendingPathComponent("receipt.json"), limit: 16384))
            return record.module == module ? (folder, record) : nil
        }.sorted { $0.1.created < $1.1.created }
    }
    public func history(module: String, currentVersion: String? = nil) throws -> String {
        let git = DevelopmentGit(directory: directory.appendingPathComponent("history/" + WebIsolation.digest(Data(module.utf8))))
        var rows: [[String:String]] = []
        let entries = try records(module)
        let currentID = entries.last(where: { $0.1.version == currentVersion && $0.1.status == "active" })?.1.id
        for (folder, record) in entries {
            var commit = ""
            if record.status == "active" {
                let source = try WebFiles.retained(at: folder)
                guard try source.digest == record.after else { throw KilnError.message("Retained source integrity failed") }
                commit = try git.commit(id: record.id, version: record.version, files: source.files)
            }
            rows.append(["id":record.id,"current":record.id == currentID ? "yes" : "no","version":record.version,"status":record.status,"created":record.created.ISO8601Format(),"commit":commit,"summary":String(record.result.split(separator: "\n").first ?? "Source change")])
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: Array(rows.reversed()), options: [.sortedKeys]), as: UTF8.self)
    }
    private func retained(_ module: String, id: String) throws -> (URL, WebChange) {
        let all = try records(module)
        guard let item = id == "latest" ? all.last(where: { $0.1.status == "active" }) : all.first(where: { $0.1.id == id }), UUID(uuidString: item.1.id) != nil else { throw KilnError.message("Unknown retained source change") }
        return item
    }
    /// The complete retained source, independent of the current workspace or running release.
    public func code(module: String, id: String) throws -> String {
        let (folder, receipt) = try retained(module, id: id)
        let snapshot = try WebFiles.retained(at: folder)
        guard try snapshot.digest == receipt.after else { throw KilnError.message("Retained source integrity failed") }
        let source = snapshot.files["App.swift"]!
        let lines = String(decoding: source, as: UTF8.self).components(separatedBy: "\n")
        let numbered = lines.enumerated().map { String(format: "%5d | ", $0.offset + 1) + $0.element }.joined(separator: "\n")
        return "Change \(receipt.id) / \(receipt.status)\nRelease \(receipt.version)\nFile App.swift / complete retained source\n" + numbered
    }
    public func diff(module: String, id: String) throws -> String {
        let (folder, receipt) = try retained(module, id: id)
        let before = try WebFiles.retained(at: folder, before: true), after = try WebFiles.retained(at: folder)
        guard try before.digest == receipt.before, try after.digest == receipt.after else { throw KilnError.message("Retained source integrity failed") }
        let git = DevelopmentGit(directory: directory.appendingPathComponent("history/" + WebIsolation.digest(Data(module.utf8))))
        return "Change \(receipt.id) / \(receipt.status)\nRelease \(receipt.version)\n--- Before.swift\n+++ App.swift\n" + (try git.diff(before: before.files, after: after.files))
    }
    public func restore(module: String, id: String, owner: String, target: ApplicationManifest,
                        validate: @escaping @Sendable () throws -> Void, deploy: @escaping @Sendable (String) async throws -> String) async throws -> String {
        let (folder, receipt) = try retained(module, id: id)
        guard receipt.status == "active" else { throw KilnError.message("Only a published source version can be restored") }
        let source = try WebFiles.retained(at: folder)
        guard try source.digest == receipt.after else { throw KilnError.message("Retained source integrity failed") }
        return try await change(module: module, owner: owner, edits: "[]", target: target, restoring: source.files, progress: { _ in }, validate: validate, deploy: deploy)
    }
    public func rollback(module: String, currentVersion: String, previousVersion: String, owner: String,
                         validate: @escaping @Sendable () throws -> Void, perform: @escaping @Sendable () async throws -> String) async throws -> String {
        guard !busy.contains(module) else { throw KilnError.message("Development app has an unfinished change") }
        try validate()
        let config = try project(module).configuration
        guard let (folder, current) = try records(module).last(where: { $0.1.version == currentVersion && $0.1.status == "active" }) else { throw KilnError.message("No source receipt matches this running release; source-aware rollback cannot be verified") }
        let previousMatches = try current.previousVersion == previousVersion || (records(module).contains { $0.1.version == previousVersion && $0.1.after == current.before && $0.1.status == "active" })
        guard previousMatches else { throw KilnError.message("Previous release has no matching source evidence; inspect history before rollback") }
        let before = try WebFiles.read(config), after = try WebFiles.retained(at: folder, before: true)
        guard try before.digest == current.after, try after.digest == current.before else { throw KilnError.message("Source changed independently; rollback will not overwrite uncommitted source") }
        let id = UUID().uuidString.lowercased(), job = jobs.appendingPathComponent(id)
        guard try FileManager.default.contentsOfDirectory(atPath: jobs.path).count < 32 else { throw KilnError.message("Development history limit reached") }
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var receipt = WebChange(id: id, module: module, owner: owner, before: current.after, after: current.before, version: previousVersion, status: "publishing")
        receipt.previousVersion = currentVersion
        try before.save(at: job, before: true); try after.save(at: job); try save(receipt, at: job)
        busy.insert(module); activeJobs.insert(id)
        defer { busy.remove(module); activeJobs.remove(id) }
        do {
            let result = try await perform()
            receipt.status = "active-source-pending"; receipt.result = result; try save(receipt, at: job)
            try validate()
            try after.install(config, expected: before)
            receipt.status = "active"; receipt.result = "Source-aware rollback. " + result; try save(receipt, at: job)
            return receipt.result + "\nRestored source SHA256 \(receipt.after). Change \(id)."
        } catch {
            receipt.status = "outcome-unconfirmed"; receipt.result = "Inspect release and source before retrying rollback. " + String(describing: error); try? save(receipt, at: job)
            throw KilnError.message(receipt.result)
        }
    }
    public func change(module: String, owner: String, edits: String, target: ApplicationManifest,
                       publish: Bool = true, operationLimit: Int = 8, refactorScope: WebRefactor? = nil, restoring: [String: Data]? = nil, progress: @escaping @Sendable (String) -> Void,
                       validate: @escaping @Sendable () throws -> Void,
                       deploy: @escaping @Sendable (String) async throws -> String) async throws -> String {
        guard WebIsolation.supported else { throw KilnError.message("Web coding currently requires macOS isolation") }
        if let refactorScope { try verifyRefactor(refactorScope, module: module) }
        guard !busy.contains(module), busy.count < 2 else { throw KilnError.message("A web change is already building; inspect web changes") }
        try validate(); try Task.checkCancellation()
        let registered = try project(module), config = registered.configuration
        guard config.autoPublish, target.id == module, target.ingressPort == config.ingressPort, (target.secrets ?? [:]).isEmpty else { throw KilnError.message("This module has no automatic development-publish grant") }
        let registrations = try bounded(projectFile(module), limit: 1_048_576)
        let before = try WebFiles.read(config)
        let after = try restoring.map { WebFiles(files: $0) } ?? before.applying(edits, multiFile: config.root != nil, limit: operationLimit)
        if after.files.keys.contains(where: { $0.hasPrefix("Views/") && $0.hasSuffix(".html") }), registered.sdk.htmlTemplates != true { throw KilnError.message("Registered SDK does not support HTML templates; an administrator must export and register an updated SDK") }
        try after.validate()
        guard after != before, config.root != nil || after.files.count == 1 else { throw KilnError.message("Changed project requires an explicit root grant") }
        let entries = try FileManager.default.contentsOfDirectory(atPath: jobs.path)
        guard entries.count < 32 else { throw KilnError.message("Development artifact limit reached (32); retained active/rollback artifacts must not be removed blindly") }
        try registered.sdk.verifyInputs()
        let id = UUID().uuidString.lowercased(), version = "dev-" + UUID().uuidString.lowercased()
        let job = jobs.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var receipt = WebChange(id: id, module: module, owner: owner, before: try before.digest, after: try after.digest, version: version, status: "building")
        receipt.previousVersion = target.version
        try save(receipt, at: job)
        try after.save(at: job)
        try before.save(at: job, before: true)
        try after.writeSources(at: job.appendingPathComponent("Sources"))
        try KilnStateFile.write(JSONEncoder().encode(registered.sdk), to: job.appendingPathComponent("sdk.json"))
        busy.insert(module); activeJobs.insert(id)
        defer { busy.remove(module); activeJobs.remove(id) }
        do {
            progress("Building isolated source change for " + module)
            try await compile(sdk: registered.sdk, job: job)
            try Task.checkCancellation(); try validate(); try registered.sdk.verifyInputs()
            guard try bounded(projectFile(module), limit: 1_048_576) == registrations,
                  try WebFiles.read(config) == before else { throw KilnError.message("Source or registration changed during the build; prepare a fresh change") }
            let binary = job.appendingPathComponent("app")
            let binaryData = try bounded(binary, limit: 134_217_728)
            if !publish {
                receipt.status = "validated"
                receipt.result = "Isolated compile passed. Source and live release were not changed."
                try save(receipt, at: job)
                return "Validation \(id): \(receipt.result) Proposed source SHA256 \(receipt.after). Publishing recompiles against current source; validation is not a deployment receipt."
            }
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
            guard try WebFiles.read(config) == before else { throw KilnError.message("Release is active but source changed independently; source was not overwritten") }
            try after.install(config, expected: before)
            receipt.status = "active"; try save(receipt, at: job)
            return "Published development change \(id.prefix(8)).\nService: \(module) · healthy\nBuild: isolated Swift compilation passed\nSource: \(after.files.count) project file(s) saved · SHA256 \(receipt.after.prefix(12))\nPreview: \(config.publicOrigin)\nHistory and diff: Services → Changes / diffs\nDevelopment browser reload is automatic; browser delivery is checked separately."
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
    func compile(sdk: WebBuildSDK, job: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sdk.builder); process.arguments = [job.path]
        process.currentDirectoryURL = job
        process.environment = ["HOME": job.path, "TMPDIR": job.path + "/", "PATH": "/usr/bin:/bin"]
        let log = job.appendingPathComponent("build.log")
        try KilnStateFile.write(Data(), to: log)
        let output = try FileHandle(forWritingTo: log); defer { try? output.close() }
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = output
        try process.run()
        defer {
            if process.isRunning {
                _ = kill(-process.processIdentifier, SIGKILL); _ = kill(process.processIdentifier, SIGKILL)
                let cleanupDeadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < cleanupDeadline { usleep(10000) }
            }
        }
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning {
            try Task.checkCancellation()
            let size = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? NSNumber)?.intValue ?? 0
            guard Date() < deadline, size <= 65536 else { throw KilnError.message("Build exceeded its time or diagnostic limit") }
            try await Task.sleep(for: .milliseconds(50))
        }
        // isRunning has already observed termination. waitUntilExit may wait
        // on the launch thread's run loop after an async executor hop on macOS.
        guard process.terminationStatus == 0 else { throw KilnError.message("Isolated compiler failed") }
    }
}
private extension ApplicationManifest { var id: String { application + "/" + name } }
