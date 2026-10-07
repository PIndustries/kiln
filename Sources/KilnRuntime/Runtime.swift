import Foundation
import KilnKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Apps are trusted native programs in separate OS processes, not in-process plugins.
public actor KilnRuntime {
    private struct Installation: Codable {
        var manifest: ApplicationManifest
        var desiredRunning: Bool
    }
    private struct Running {
        var process: Process
        var log: FileHandle
    }
    public let stateDirectory: URL
    private var installed: [String: Installation] = [:]
    private var running: [String: Running] = [:]
    private var shuttingDown = false
    private var stopping: Set<String> = []

    public init(stateDirectory: URL) throws {
        self.stateDirectory = stateDirectory
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let index = stateDirectory.appendingPathComponent("applications.json")
        if FileManager.default.fileExists(atPath: index.path) {
            installed = try JSONDecoder().decode([String: Installation].self, from: Data(contentsOf: index))
            for installation in installed.values { try installation.manifest.validate() }
        }
    }

    private func save() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(installed).write(to: stateDirectory.appendingPathComponent("applications.json"), options: .atomic)
    }

    public func restore() throws {
        for name in installed.keys.sorted() where installed[name]?.desiredRunning == true { try launch(name) }
    }

    public func install(path: String) throws -> String {
        guard !shuttingDown else { throw KilnError.message("Runtime is shutting down") }
        var manifest = try JSONDecoder().decode(ApplicationManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try manifest.validate()
        let id = "\(manifest.application)/\(manifest.name)"
        guard installed[id] == nil else { throw KilnError.message("Application already installed; updates are not implemented yet") }
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
        let logs = stateDirectory.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let logURL = logs.appendingPathComponent("\(name).log")
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let log = try FileHandle(forWritingTo: logURL); try log.seekToEnd()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: installation.manifest.executable)
        process.arguments = installation.manifest.arguments
        // Do not inherit the supervisor's credentials or shell environment.
        let dataDirectory = stateDirectory.appendingPathComponent("data/\(name)")
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        process.currentDirectoryURL = dataDirectory
        process.environment = ["PATH": "/usr/bin:/bin", "KILN_APP_NAME": name, "KILN_DATA_DIR": dataDirectory.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log; process.standardError = log
        do { try process.run() } catch { try? log.close(); throw error }
        running[name] = Running(process: process, log: log)
    }

    public func start(_ name: String) throws -> String {
        try launch(name)
        installed[name]?.desiredRunning = true
        do { try save() } catch { running[name]?.process.terminate(); throw error }
        return "Started \(name) pid=\(running[name]!.process.processIdentifier)"
    }

    public func stop(_ name: String) async throws -> String {
        guard installed[name] != nil else { throw KilnError.message("Unknown application: \(name)") }
        installed[name]?.desiredRunning = false
        try save()
        await terminate(name)
        return "Stopped \(name)"
    }

    private func terminate(_ name: String) async {
        guard let entry = running.removeValue(forKey: name) else { return }
        stopping.insert(name)
        defer { stopping.remove(name) }
        if entry.process.isRunning {
            entry.process.terminate()
            for _ in 0..<30 {
                if !entry.process.isRunning { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if entry.process.isRunning { kill(entry.process.processIdentifier, SIGKILL) }
        }
        try? entry.log.close()
    }

    public func list() -> String {
        guard !installed.isEmpty else { return "No applications installed." }
        return (["APPLICATION\tMODULE\tVERSION\tSTATE\tPID"] + installed.keys.sorted().map { name in
            let entry = running[name]
            let alive = entry?.process.isRunning == true
            let status = alive ? "running" : (installed[name]!.desiredRunning ? "exited" : "stopped")
            return "\(installed[name]!.manifest.application)\t\(installed[name]!.manifest.name)\t\(installed[name]!.manifest.version)\t\(status)\t\(alive ? String(entry!.process.processIdentifier) : "-")"
        }).joined(separator: "\n")
    }

    public func health(_ name: String) async throws -> String {
        guard let item = installed[name] else { throw KilnError.message("Unknown application") }
        guard running[name]?.process.isRunning == true else { throw KilnError.message("Application is not running") }
        guard let raw = item.manifest.healthURL, let url = URL(string: raw) else { return "Running; no health endpoint configured" }
        var request = URLRequest(url: url); request.timeoutInterval = 2
        let (_, response) = try await URLSession.shared.data(for: request)
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
        for name in Array(running.keys) { await terminate(name) }
    }
}
