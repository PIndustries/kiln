import Foundation
import KilnKit
import KilnIngress
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private final class LocalHealthPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Apps are trusted native programs in separate OS processes, not in-process plugins.
public actor KilnRuntime {
    private struct Installation: Codable {
        var manifest: ApplicationManifest
        var desiredRunning: Bool
        var previous: ApplicationManifest? = nil
    }
    private struct Running {
        var process: Process
        var log: FileHandle
    }
    public nonisolated let stateDirectory: URL
    private var installed: [String: Installation] = [:]
    private var running: [String: Running] = [:]
    private var ingress: [String: KilnIngress] = [:]
    private var deploying: Set<String> = []
    private var candidates: [String: ApplicationManifest] = [:]
    private var shuttingDown = false
    private var stopping: Set<String> = []

    public init(stateDirectory: URL) throws {
        self.stateDirectory = stateDirectory
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let index = stateDirectory.appendingPathComponent("applications.json")
        if FileManager.default.fileExists(atPath: index.path) {
            installed = try JSONDecoder().decode([String: Installation].self, from: Data(contentsOf: index))
            for installation in installed.values {
                try installation.manifest.validate()
                try installation.previous?.validate()
            }
        }
    }

    private func save() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(installed).write(to: stateDirectory.appendingPathComponent("applications.json"), options: .atomic)
    }

    public func restore() async throws {
        for name in installed.keys.sorted() where installed[name]?.desiredRunning == true { _ = try await start(name) }
    }

    public func install(path: String) throws -> String {
        guard !shuttingDown else { throw KilnError.message("Runtime is shutting down") }
        var manifest = try JSONDecoder().decode(ApplicationManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try manifest.validate()
        let id = "\(manifest.application)/\(manifest.name)"
        guard !deploying.contains(id) else { throw KilnError.message("Deployment in progress") }
        guard installed[id] == nil else { throw KilnError.message("Application already installed; use app deploy for managed ingress releases") }
        guard FileManager.default.isExecutableFile(atPath: manifest.executable) else { throw KilnError.message("Executable is missing or not executable") }
        let directory = stateDirectory.appendingPathComponent("releases/\(id)/\(manifest.version)")
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw KilnError.message("Release directory already exists") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let destination = directory.appendingPathComponent("app")
            try FileManager.default.copyItem(atPath: manifest.executable, toPath: destination.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
            manifest.executable = destination.path
            installed[id] = Installation(manifest: manifest, desiredRunning: false)
            try save()
        } catch {
            installed.removeValue(forKey: id)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return "Installed \(id)@\(manifest.version). Run: app start \(id)"
    }

    private func launch(_ name: String) throws {
        guard !shuttingDown, let installation = installed[name] else { throw KilnError.message("Unknown application: \(name)") }
        guard !stopping.contains(name) else { throw KilnError.message("Application is stopping") }
        if running[name]?.process.isRunning == true { throw KilnError.message("Application is already running") }
        if let old = running.removeValue(forKey: name) { try? old.log.close() }
        running[name] = try spawn(installation.manifest)
    }

    private func spawn(_ manifest: ApplicationManifest) throws -> Running {
        let name = "\(manifest.application)/\(manifest.name)"
        let logs = stateDirectory.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let logURL = logs.appendingPathComponent("\(name).log")
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let log = try FileHandle(forWritingTo: logURL); try log.seekToEnd()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: manifest.executable)
        process.arguments = manifest.arguments
        // Do not inherit the supervisor's credentials or shell environment.
        let dataDirectory = stateDirectory.appendingPathComponent("data/\(name)")
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        process.currentDirectoryURL = dataDirectory
        process.environment = ["PATH": "/usr/bin:/bin", "KILN_APP_NAME": name, "KILN_DATA_DIR": dataDirectory.path, "KILN_RELEASE_VERSION": manifest.version]
        if manifest.ingressPort != nil { process.environment?["KILN_PORT"] = String(workerPort(manifest)) }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log; process.standardError = log
        do { try process.run() } catch { try? log.close(); throw error }
        return Running(process: process, log: log)
    }

    public func start(_ name: String) async throws -> String {
        guard !deploying.contains(name) else { throw KilnError.message("Deployment in progress") }
        deploying.insert(name)
        defer { deploying.remove(name) }
        try launch(name)
        do {
            if let manifest = installed[name]?.manifest, let port = manifest.ingressPort {
                try await ready(manifest, process: running[name]!.process)
                if ingress[name] == nil {
                    let listener = KilnIngress()
                    do { try await listener.start(port: port) }
                    catch { await listener.stop(); throw error }
                    ingress[name] = listener
                }
            }
            guard !shuttingDown else { throw KilnError.message("Runtime is shutting down") }
            let previousDesired = installed[name]?.desiredRunning ?? false
            installed[name]?.desiredRunning = true
            do { try save() } catch { installed[name]?.desiredRunning = previousDesired; throw error }
            if let manifest = installed[name]?.manifest, manifest.ingressPort != nil {
                ingress[name]?.switchTo(workerPort(manifest))
            }
        } catch {
            await terminate(name)
            throw error
        }
        return "Started \(name) pid=\(running[name]!.process.processIdentifier)"
    }

    public func stop(_ name: String) async throws -> String {
        guard !deploying.contains(name) else { throw KilnError.message("Deployment in progress") }
        guard installed[name] != nil else { throw KilnError.message("Unknown application: \(name)") }
        let previousDesired = installed[name]!.desiredRunning
        installed[name]?.desiredRunning = false
        do { try save() } catch { installed[name]?.desiredRunning = previousDesired; throw error }
        ingress[name]?.switchTo(nil)
        await terminate(name)
        return "Stopped \(name)"
    }

    private func terminate(_ name: String) async {
        guard let entry = running.removeValue(forKey: name) else { return }
        stopping.insert(name)
        defer { stopping.remove(name) }
        await terminateEntry(entry)
    }

    private func terminateEntry(_ entry: Running) async {
        if entry.process.isRunning {
            entry.process.terminate()
            for _ in 0..<30 {
                if !entry.process.isRunning { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if entry.process.isRunning {
                kill(entry.process.processIdentifier, SIGKILL)
                for _ in 0..<20 {
                    if !entry.process.isRunning { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
        try? entry.log.close()
    }

    public func snapshot() -> [ModuleSnapshot] {
        installed.keys.sorted().map { id in
            let manifest = installed[id]!.manifest
            let process = running[id]?.process
            let alive = process?.isRunning == true
            return ModuleSnapshot(application: manifest.application, name: manifest.name,
                version: manifest.version,
                state: stopping.contains(id) ? "stopping" : alive ? "running" : installed[id]!.desiredRunning ? "exited" : "stopped",
                pid: alive ? process?.processIdentifier : nil)
        }
    }

    public func list() -> String {
        let modules = snapshot()
        guard !modules.isEmpty else { return "No applications installed." }
        let rows = [["APPLICATION", "MODULE", "VERSION", "STATE", "PID"]] + modules.map {
            [$0.application, $0.name, $0.version, $0.state, $0.pid.map(String.init) ?? "-"]
        }
        let widths = (0..<5).map { column in min(40, rows.map { $0[column].count }.max() ?? 0) }
        return rows.map { row in row.enumerated().map { column, value in
            String(value.prefix(widths[column])).padding(toLength: widths[column], withPad: " ", startingAt: 0)
        }.joined(separator: "  ") }.joined(separator: "\n")
    }

    public func health(_ name: String) async throws -> String {
        guard let item = installed[name] else { throw KilnError.message("Unknown application") }
        guard running[name]?.process.isRunning == true else { throw KilnError.message("Application is not running") }
        guard let raw = item.manifest.healthURL, let url = URL(string: raw) else { return "Running; no health endpoint configured" }
        var request = URLRequest(url: url); request.timeoutInterval = 2
        let session = URLSession(configuration: .ephemeral, delegate: LocalHealthPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw KilnError.message("Health check failed") }
        return "\(name): healthy (HTTP 200)"
    }

    public func logs(_ name: String) throws -> String {
        guard installed[name] != nil else { throw KilnError.message("Unknown application") }
        let file = try FileHandle(forReadingFrom: stateDirectory.appendingPathComponent("logs/\(name).log"))
        defer { try? file.close() }
        let size = try file.seekToEnd(); try file.seek(toOffset: size > 8192 ? size - 8192 : 0)
        return String(decoding: try file.readToEnd() ?? Data(), as: UTF8.self)
    }

    public func shutdown() async {
        shuttingDown = true
        while !deploying.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        for listener in ingress.values { await listener.stop() }
        ingress.removeAll()
        for name in Array(running.keys) { await terminate(name) }
    }
}


extension KilnRuntime {
    private func workerPort(_ manifest: ApplicationManifest) -> Int {
        URL(string: manifest.healthURL!)!.port!
    }

    private func ready(_ manifest: ApplicationManifest, process: Process) async throws {
        guard let raw = manifest.healthURL, let url = URL(string: raw) else {
            throw KilnError.message("Deployment requires a health endpoint")
        }
        let session = URLSession(configuration: .ephemeral, delegate: LocalHealthPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // Require consecutive successes while the candidate process remains alive.
        var successes = 0
        for _ in 0..<40 {
            guard !shuttingDown, process.isRunning else { throw KilnError.message("Candidate exited or runtime is shutting down") }
            var request = URLRequest(url: url); request.timeoutInterval = 0.5
            request.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (_, response) = try await session.data(for: request)
                successes = (response as? HTTPURLResponse)?.statusCode == 200 ? successes + 1 : 0
            } catch { successes = 0 }
            if successes >= 3, process.isRunning { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw KilnError.message("Candidate failed readiness; active release unchanged")
    }

    public func allowIngress(host: String, port: Int) -> Bool {
        host == "127.0.0.1" && installed.contains { name, item in
            item.desiredRunning && item.manifest.ingressPort == port && ingress[name] != nil
        }
    }

    public func releases(_ name: String) throws -> String {
        guard let item = installed[name] else { throw KilnError.message("Unknown application") }
        return "Active: \(item.manifest.version)\nPrevious: \(item.previous?.version ?? "none")\nIngress: \(item.manifest.ingressPort.map { "127.0.0.1:\($0)" } ?? "none")"
    }

    public func deploy(path: String) async throws -> String {
        var manifest = try JSONDecoder().decode(ApplicationManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try manifest.validate()
        guard manifest.ingressPort != nil else { throw KilnError.message("app deploy requires ingressPort") }
        let name = "\(manifest.application)/\(manifest.name)"
        guard !shuttingDown, !deploying.contains(name), !stopping.contains(name) else { throw KilnError.message("Application is busy or shutting down") }
        deploying.insert(name)
        defer { deploying.remove(name) }
        let directory = stateDirectory.appendingPathComponent("releases/\(name)/\(manifest.version)")
        guard !FileManager.default.fileExists(atPath: directory.path), FileManager.default.isExecutableFile(atPath: manifest.executable) else {
            throw KilnError.message("Release version already exists or executable is unavailable")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let destination = directory.appendingPathComponent("app")
            try FileManager.default.copyItem(atPath: manifest.executable, toPath: destination.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
            manifest.executable = destination.path
            return try await activate(manifest)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    public func rollback(_ name: String) async throws -> String {
        guard !shuttingDown, !deploying.contains(name), !stopping.contains(name) else { throw KilnError.message("Application is busy or shutting down") }
        guard let previous = installed[name]?.previous else { throw KilnError.message("No previous release") }
        deploying.insert(name)
        defer { deploying.remove(name) }
        return try await activate(previous)
    }

    private func activate(_ manifest: ApplicationManifest) async throws -> String {
        let name = "\(manifest.application)/\(manifest.name)"
        let old = installed[name]
        if let old, old.manifest.ingressPort != manifest.ingressPort {
            throw KilnError.message("Ingress port must remain stable across releases")
        }
        let port = workerPort(manifest)
        guard !installed.values.contains(where: { item in
            item.manifest.healthURL.flatMap(URL.init(string:))?.port == port
        }) else { throw KilnError.message("Candidate needs a distinct worker port") }
        guard !installed.contains(where: { $0.key != name && $0.value.manifest.ingressPort == manifest.ingressPort }) else {
            throw KilnError.message("Ingress port already assigned")
        }
        let others = installed.filter { $0.key != name }.map { $0.value.manifest } + Array(candidates.values)
        let requested = Set([port, manifest.ingressPort!])
        guard !others.contains(where: { item in
            let ports = [item.ingressPort, item.healthURL.flatMap(URL.init(string:))?.port].compactMap { $0 }
            return !requested.isDisjoint(with: ports)
        }) else { throw KilnError.message("Worker or ingress port is already reserved") }
        candidates[name] = manifest
        defer { candidates.removeValue(forKey: name) }
        let candidate = try spawn(manifest)
        var newListener: KilnIngress?
        do {
            try await ready(manifest, process: candidate.process)
            if ingress[name] == nil {
                let listener = KilnIngress(); newListener = listener
                try await listener.start(port: manifest.ingressPort!)
            }
            guard !shuttingDown else { throw KilnError.message("Runtime is shutting down") }
            installed[name] = Installation(manifest: manifest, desiredRunning: true, previous: old?.manifest)
            do { try save() } catch { installed[name] = old; throw error }
        } catch {
            await newListener?.stop()
            await terminateEntry(candidate)
            throw error
        }
        if let newListener { ingress[name] = newListener }
        let previousProcess = running.updateValue(candidate, forKey: name)
        ingress[name]!.switchTo(port)
        if let previousProcess {
            if let old, old.manifest.ingressPort != nil { await ingress[name]!.drain(workerPort(old.manifest)) }
            await terminateEntry(previousProcess)
        }
        return "Active \(name)@\(manifest.version) via 127.0.0.1:\(manifest.ingressPort!) (healthy; previous connections drained)"
    }
}
