import Foundation
import KilnKit
import KilnVault
import KilnIngress
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private final class GuardianBundleMarker: NSObject {}

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
    private struct IndexEnvelope: Codable {
        let formatVersion: Int
        let applications: [String: Installation]
    }
    private struct IndexHeader: Decodable { let formatVersion: Int? }
    private var versionedIndex = false
    private struct Running {
        var process: Process
        var log: FileHandle
        var lifetime: FileHandle
        var workerPID: Int32
        var resourceID: String?
    }
    public nonisolated let stateDirectory: URL
    public nonisolated var vault: KilnVault { KilnVault(directory: stateDirectory) }
    private var installed: [String: Installation] = [:]
    private var running: [String: Running] = [:]
    private var ingress: [String: KilnIngress] = [:]
    private var deploying: Set<String> = []
    private var candidates: [String: ApplicationManifest] = [:]
    private var shuttingDown = false
    private var persistenceFault = false
    private var stopping: Set<String> = []
    private var supervision: Task<Void, Never>?
    private struct Recovery {
        var attempts = 0
        var nextAttempt: Date = .distantPast
        var healthySince: Date?
    }
    private var recovery: [String: Recovery] = [:]

    private func beginSupervision() {
        guard supervision == nil, !shuttingDown else { return }
        supervision = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                guard let self else { break }
                await self.reconcileWorkers()
            }
        }
    }

    private func reconcileWorkers() async {
        for name in installed.keys.sorted() {
            guard !shuttingDown, !persistenceFault, installed[name]?.desiredRunning == true,
                  installed[name]?.manifest.restartPolicy == .always,
                  !deploying.contains(name), !stopping.contains(name) else { continue }
            var state = recovery[name] ?? Recovery()
            if running[name]?.process.isRunning == true {
                if state.healthySince == nil { state.healthySince = Date() }
                if Date().timeIntervalSince(state.healthySince!) >= 60 { state.attempts = 0 }
                recovery[name] = state
                continue
            }
            ingress[name]?.switchTo(nil)
            state.healthySince = nil
            guard state.attempts < 3 else { recovery[name] = state; continue }
            if state.nextAttempt == .distantPast {
                state.nextAttempt = Date().addingTimeInterval(pow(2, Double(state.attempts)))
            }
            recovery[name] = state
            guard Date() >= state.nextAttempt else { continue }
            state.attempts += 1
            state.nextAttempt = .distantPast
            recovery[name] = state
            // start uses the same readiness and deployment exclusion rules as operator actions.
            _ = try? await start(name, automatic: true)
        }
    }

    public init(stateDirectory: URL) throws {
        self.stateDirectory = stateDirectory
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let index = stateDirectory.appendingPathComponent("applications.json")
        if FileManager.default.fileExists(atPath: index.path) {
            let data = try Data(contentsOf: index)
            let decoder = JSONDecoder()
            if let version = try decoder.decode(IndexHeader.self, from: data).formatVersion {
                guard version == 2 else { throw KilnError.message("Unsupported application state format; use a compatible Kiln version") }
                installed = try decoder.decode(IndexEnvelope.self, from: data).applications
                versionedIndex = true
            } else {
                installed = try decoder.decode([String: Installation].self, from: data)
            }
            for installation in installed.values {
                try installation.manifest.validate()
                try installation.previous?.validate()
            }
        }
    }

    private func save() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let needsEnvelope = versionedIndex || installed.values.contains {
            $0.manifest.resources != nil || $0.previous?.resources != nil
        }
        let data: Data
        if needsEnvelope { data = try encoder.encode(IndexEnvelope(formatVersion: 2, applications: installed)) }
        else { data = try encoder.encode(installed) }
        do {
            try KilnStateFile.write(data, to: stateDirectory.appendingPathComponent("applications.json"))
            versionedIndex = needsEnvelope
        } catch let error as KilnStateFile.CommitUncertain {
            versionedIndex = needsEnvelope
            persistenceFault = true
            throw error
        }
    }

    private func flushRelease(_ executable: URL) throws {
        // The index must never become durable before the executable it names.
        func normalizedPath(_ url: URL) -> String {
            var path = url.standardizedFileURL.path
            while path.count > 1 && path.last == "/" { path.removeLast() }
            return path
        }
        let root = normalizedPath(stateDirectory)
        var item = executable.standardizedFileURL
        while true {
            let path = normalizedPath(item)
            // Compare filesystem paths, not URL directory flags. Foundation on
            // Linux distinguishes a directory URL with/without its trailing slash.
            guard path == root || path.hasPrefix(root == "/" ? "/" : root + "/") else {
                throw KilnError.message("Release is outside runtime state directory")
            }
            let descriptor = open(path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { throw KilnError.message("Cannot open release for persistence") }
            let result = fsync(descriptor)
            close(descriptor)
            guard result == 0 else { throw KilnError.message("Cannot flush release before activation") }
            if path == root { break }
            let parent = item.deletingLastPathComponent()
            guard normalizedPath(parent) != path else { throw KilnError.message("Release is outside runtime state directory") }
            item = parent
        }
    }

    private func stageRelease(_ manifest: ApplicationManifest) throws -> URL {
        let directory = stateDirectory.appendingPathComponent("pending-releases")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let marker = directory.appendingPathComponent(UUID().uuidString + ".json")
        // Record intent BEFORE creating the directory, closing the empty-directory
        // crash window. A marker left after commit is harmless and is reconciled.
        try KilnStateFile.write(JSONEncoder().encode(manifest), to: marker)
        return marker
    }

    private func removeInterruptedReleases() throws {
        let directory = stateDirectory.appendingPathComponent("pending-releases")
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let retained = Set(installed.values.flatMap { [$0.manifest, $0.previous].compactMap { $0 }.map {
            "\($0.application)/\($0.name)/\($0.version)"
        } })
        for marker in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where marker.pathExtension == "json" {
            let manifest = try JSONDecoder().decode(ApplicationManifest.self, from: Data(contentsOf: marker))
            try manifest.validate()
            let release = "\(manifest.application)/\(manifest.name)/\(manifest.version)"
            if !retained.contains(release) {
                let path = stateDirectory.appendingPathComponent("releases/" + release)
                if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
            }
            try FileManager.default.removeItem(at: marker)
        }
    }

    public func restore() async throws {
        try KilnWorkerGuardian.reconcile(directory: stateDirectory)
        try ResourceController.reconcile(state: stateDirectory)
        try removeInterruptedReleases()
        beginSupervision()
        // A broken worker must not prevent other installations or the management plane starting.
        for name in installed.keys.sorted() where installed[name]?.desiredRunning == true {
            _ = try? await start(name)
        }
    }

    public func install(path: String) throws -> String {
        guard !shuttingDown, !persistenceFault else { throw KilnError.message("Runtime is shutting down or requires recovery after a state persistence failure") }
        var manifest = try JSONDecoder().decode(ApplicationManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try manifest.validate()
        try ResourceController.ensureSupported(manifest.resources)
        let id = "\(manifest.application)/\(manifest.name)"
        guard !deploying.contains(id) else { throw KilnError.message("Deployment in progress") }
        guard installed[id] == nil else { throw KilnError.message("Application already installed; use app deploy for managed ingress releases") }
        guard FileManager.default.isExecutableFile(atPath: manifest.executable) else { throw KilnError.message("Executable is missing or not executable") }
        let directory = stateDirectory.appendingPathComponent("releases/\(id)/\(manifest.version)")
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw KilnError.message("Release directory already exists") }
        let staging = try stageRelease(manifest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let destination = directory.appendingPathComponent("app")
            try FileManager.default.copyItem(atPath: manifest.executable, toPath: destination.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
            try flushRelease(destination)
            manifest.executable = destination.path
            installed[id] = Installation(manifest: manifest, desiredRunning: false)
            try save()
        } catch {
            if !persistenceFault {
                installed.removeValue(forKey: id)
                try? FileManager.default.removeItem(at: directory)
                try? FileManager.default.removeItem(at: staging)
            }
            throw error
        }
        try? FileManager.default.removeItem(at: staging)
        return "Installed \(id)@\(manifest.version). Run: app start \(id)"
    }

    private func launch(_ name: String) throws {
        guard !shuttingDown, !persistenceFault, let installation = installed[name] else { throw KilnError.message("Unknown application: \(name)") }
        guard !stopping.contains(name) else { throw KilnError.message("Application is stopping") }
        if running[name]?.process.isRunning == true { throw KilnError.message("Application is already running") }
        if let old = running[name] {
            if let id = old.resourceID { try ResourceController.finish(id: id, state: stateDirectory) }
            running.removeValue(forKey: name)
            try? old.lifetime.close(); try? old.log.close()
        }
        running[name] = try spawn(installation.manifest)
    }

    private func spawn(_ manifest: ApplicationManifest) throws -> Running {
        let name = "\(manifest.application)/\(manifest.name)"
        guard FileManager.default.isExecutableFile(atPath: manifest.executable) else {
            throw KilnError.message("Worker executable is missing or not executable")
        }
        try ResourceController.ensureSupported(manifest.resources)
        let resourceID = manifest.resources.map { _ in UUID().uuidString }
        let resourceRoot = manifest.resources == nil ? nil : try ResourceController.prepare(required: true)
        let secrets = try vault.environment(for: name, bindings: manifest.secrets ?? [:])
        let logs = stateDirectory.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let logURL = logs.appendingPathComponent("\(name).log")
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let log = try FileHandle(forWritingTo: logURL); try log.seekToEnd()
        let process = Process()
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var guardian = executable.lastPathComponent == "kiln" ? executable : executable.deletingLastPathComponent().appendingPathComponent("kiln")
        #if os(macOS)
        // SwiftPM places the test runner inside an XCTest bundle, while executable
        // products are beside that bundle. Linux runners already use siblings.
        var ancestor = Bundle(for: GuardianBundleMarker.self).bundleURL
        if ancestor.pathExtension != "xctest" { ancestor = executable.deletingLastPathComponent() }
        while ancestor.path != "/" {
            if ancestor.pathExtension == "xctest" {
                guardian = ancestor.deletingLastPathComponent().appendingPathComponent("kiln")
                break
            }
            ancestor.deleteLastPathComponent()
        }
        #endif
        guard FileManager.default.isExecutableFile(atPath: guardian.path) else {
            try? log.close()
            throw KilnError.message("Worker guardian executable is unavailable: " + guardian.path)
        }
        process.executableURL = guardian
        process.arguments = ["worker-guardian", stateDirectory.path, manifest.executable] + manifest.arguments
        // Do not inherit the supervisor's credentials or shell environment.
        let dataDirectory = stateDirectory.appendingPathComponent("data/\(name)")
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        process.currentDirectoryURL = dataDirectory
        process.environment = ["PATH": "/usr/bin:/bin", "KILN_APP_NAME": name, "KILN_DATA_DIR": dataDirectory.path, "KILN_RELEASE_VERSION": manifest.version]
        if manifest.ingressPort != nil { process.environment?["KILN_PORT"] = String(workerPort(manifest)) }
        process.environment?.merge(secrets) { _, secret in secret }
        if let resourceID, let resourceRoot {
            process.environment?["KILN_RESOURCE_ROOT"] = resourceRoot.path
            process.environment?["KILN_RESOURCE_ID"] = resourceID
            process.environment?["KILN_RESOURCE_MANIFEST"] = try JSONEncoder().encode(manifest).base64EncodedString()
        }
        let lifetime = Pipe(), acknowledgement = Pipe()
        // Explicitly prevent another child inheriting a writer and delaying EOF.
        _ = fcntl(lifetime.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(lifetime.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
        process.standardInput = lifetime.fileHandleForReading
        process.standardOutput = acknowledgement.fileHandleForWriting
        process.standardError = log
        do {
            try process.run()
            try lifetime.fileHandleForReading.close()
            try acknowledgement.fileHandleForWriting.close()
            defer { try? acknowledgement.fileHandleForReading.close() }
            var response = Data()
            for _ in 0..<100 {
                var item = pollfd(fd: acknowledgement.fileHandleForReading.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                let count = poll(&item, 1, 50)
                if count > 0 {
                    var bytes = [UInt8](repeating: 0, count: 32)
                    #if canImport(Darwin)
                    let length = Darwin.read(acknowledgement.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
                    #else
                    let length = Glibc.read(acknowledgement.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
                    #endif
                    if length < 0 && errno == EINTR { continue }
                    if length <= 0 { break }
                    response.append(contentsOf: bytes.prefix(length))
                    if response.contains(10) { break }
                }
            }
            guard let pid = Int32(String(decoding: response, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
                throw KilnError.message("Worker guardian did not acknowledge launch")
            }
            return Running(process: process, log: log, lifetime: lifetime.fileHandleForWriting, workerPID: pid, resourceID: resourceID)
        } catch {
            try? lifetime.fileHandleForWriting.close()
            try? lifetime.fileHandleForReading.close()
            try? acknowledgement.fileHandleForWriting.close()
            // Acknowledgement failure must not discard a still-owning guardian:
            // another start could otherwise overlap its not-yet-reaped child.
            if process.isRunning { process.waitUntilExit() }
            if let resourceID { try ResourceController.finish(id: resourceID, state: stateDirectory) }
            try? log.close()
            throw error
        }
    }

    public func start(_ name: String) async throws -> String {
        try await start(name, automatic: false)
    }

    private func start(_ name: String, automatic: Bool) async throws -> String {
        guard !deploying.contains(name), !persistenceFault else { throw KilnError.message("Deployment in progress or state recovery required") }
        if !automatic { recovery.removeValue(forKey: name) }
        beginSupervision()
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
            guard !shuttingDown, !persistenceFault else { throw KilnError.message("Runtime is shutting down or requires recovery after a state persistence failure") }
            let previousDesired = installed[name]?.desiredRunning ?? false
            installed[name]?.desiredRunning = true
            do { try save() } catch { if !persistenceFault { installed[name]?.desiredRunning = previousDesired }; throw error }
            if let manifest = installed[name]?.manifest, manifest.ingressPort != nil {
                ingress[name]?.switchTo(workerPort(manifest))
            }
        } catch {
            await terminate(name)
            throw error
        }
        return "Started \(name) pid=\(running[name]!.workerPID)"
    }

    public func stop(_ name: String) async throws -> String {
        guard !deploying.contains(name), !persistenceFault else { throw KilnError.message("Deployment in progress or state recovery required") }
        guard installed[name] != nil else { throw KilnError.message("Unknown application: \(name)") }
        let previousDesired = installed[name]!.desiredRunning
        installed[name]?.desiredRunning = false
        do { try save() } catch { if !persistenceFault { installed[name]?.desiredRunning = previousDesired }; throw error }
        recovery.removeValue(forKey: name)
        ingress[name]?.switchTo(nil)
        await terminate(name)
        guard !persistenceFault else { throw KilnError.message("Resource descendant cleanup is unconfirmed; runtime requires recovery") }
        return "Stopped \(name)"
    }

    public func restart(_ name: String) async throws -> String {
        guard !shuttingDown, !persistenceFault, !deploying.contains(name), !stopping.contains(name), installed[name] != nil else {
            throw KilnError.message("Unknown application, application busy, or runtime requires recovery")
        }
        // Restart expresses desired running BEFORE stopping the old process. An
        // interrupted restart restores a worker without replaying an operation.
        let previousDesired = installed[name]!.desiredRunning
        installed[name]?.desiredRunning = true
        do { try save() } catch { if !persistenceFault { installed[name]?.desiredRunning = previousDesired }; throw error }
        deploying.insert(name)
        ingress[name]?.switchTo(nil)
        await terminate(name)
        deploying.remove(name)
        return try await start(name)
    }

    private func terminate(_ name: String) async {
        guard let entry = running.removeValue(forKey: name) else { return }
        stopping.insert(name)
        defer { stopping.remove(name) }
        await terminateEntry(entry)
    }

    private func terminateEntry(_ entry: Running) async {
        try? entry.lifetime.close()
        // The guardian owns and reaps the child; never kill a persisted PID.
        // Keep waiting if the child is unkillable rather than launch a duplicate.
        while entry.process.isRunning {
            // Cancellation may stop a caller waiting for an operation, but must
            // not discard ownership or turn cleanup into a hot spin.
            await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
        }
        if let id = entry.resourceID {
            do { try ResourceController.finish(id: id, state: stateDirectory) }
            catch { persistenceFault = true }
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
                state: persistenceFault ? "recovery-required" : stopping.contains(id) ? "stopping" : alive ? "running" :
                    installed[id]!.desiredRunning ? (manifest.restartPolicy == .always ?
                        ((recovery[id]?.attempts ?? 0) >= 3 ? "failed" : "recovering") : "exited") : "stopped",
                pid: alive ? running[id]?.workerPID : nil)
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

    public func resourceStatus(_ name: String) throws -> String {
        guard let installation = installed[name] else { throw KilnError.message("Unknown application") }
        guard let limits = installation.manifest.resources else {
            return "\(name): legacy trusted worker; no per-module hard resource limits configured"
        }
        if let id = running[name]?.resourceID, running[name]?.process.isRunning == true {
            return try ResourceController.status(id: id, state: stateDirectory)
        }
        let previous = stateDirectory.appendingPathComponent("resource-reports/" + name + ".txt")
        if let report = try? String(contentsOf: previous, encoding: .utf8) { return report }
        return "\(name): limits configured; no active enforcement (worker stopped or launch failed)\nmemoryBytes: \(limits.memoryBytes)\ncpuMillis: \(limits.cpuMillis)\nmaxProcesses: \(limits.maxProcesses)"
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
        supervision?.cancel()
        supervision = nil
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
        // Linux FoundationNetworking can expire fractional-second timeouts while
        // processing a response whose headers/body arrive separately (verified
        // with this NIO backend). Whole-second probes avoid premature -1001.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var successes = 0
        var lastFailure = "no successful response"
        for _ in 0..<40 {
            if ContinuousClock.now >= deadline { break }
            guard !shuttingDown, process.isRunning else { throw KilnError.message("Candidate exited or runtime is shutting down") }
            var request = URLRequest(url: url); request.timeoutInterval = 1
            request.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (_, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode
                successes = status == 200 ? successes + 1 : 0
                if status != 200 { lastFailure = status.map { "HTTP \($0)" } ?? "non-HTTP response" }
            } catch {
                successes = 0
                // Preserve a useful, credential-free reason instead of hiding
                // transport failures behind a generic readiness timeout.
                if let networkError = error as? URLError { lastFailure = "transport code \(networkError.errorCode)" }
                else { lastFailure = "transport failure" }
            }
            if successes >= 3, process.isRunning { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw KilnError.message("Candidate failed readiness (\(lastFailure)); active release unchanged")
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
        try ResourceController.ensureSupported(manifest.resources)
        guard manifest.ingressPort != nil else { throw KilnError.message("app deploy requires ingressPort") }
        let name = "\(manifest.application)/\(manifest.name)"
        guard !shuttingDown, !persistenceFault, !deploying.contains(name), !stopping.contains(name) else { throw KilnError.message("Application is busy or shutting down") }
        deploying.insert(name)
        defer { deploying.remove(name) }
        let directory = stateDirectory.appendingPathComponent("releases/\(name)/\(manifest.version)")
        guard !FileManager.default.fileExists(atPath: directory.path), FileManager.default.isExecutableFile(atPath: manifest.executable) else {
            throw KilnError.message("Release version already exists or executable is unavailable")
        }
        let staging = try stageRelease(manifest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let destination = directory.appendingPathComponent("app")
            try FileManager.default.copyItem(atPath: manifest.executable, toPath: destination.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
            try flushRelease(destination)
            manifest.executable = destination.path
            let result = try await activate(manifest)
            try? FileManager.default.removeItem(at: staging)
            return result
        } catch {
            if !persistenceFault {
                try? FileManager.default.removeItem(at: directory)
                try? FileManager.default.removeItem(at: staging)
            }
            throw error
        }
    }

    public func rollback(_ name: String) async throws -> String {
        guard !shuttingDown, !persistenceFault, !deploying.contains(name), !stopping.contains(name) else { throw KilnError.message("Application is busy or shutting down") }
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
            guard !shuttingDown, !persistenceFault else { throw KilnError.message("Runtime is shutting down or requires recovery after a state persistence failure") }
            installed[name] = Installation(manifest: manifest, desiredRunning: true, previous: old?.manifest)
            do { try save() } catch { if !persistenceFault { installed[name] = old }; throw error }
        } catch {
            await newListener?.stop()
            await terminateEntry(candidate)
            if persistenceFault {
                ingress[name]?.switchTo(nil)
                await terminate(name)
            }
            throw error
        }
        if let newListener { ingress[name] = newListener }
        let previousProcess = running.updateValue(candidate, forKey: name)
        ingress[name]!.switchTo(port)
        if let previousProcess {
            if let old, old.manifest.ingressPort != nil { await ingress[name]!.drain(workerPort(old.manifest)) }
            await terminateEntry(previousProcess)
        }
        guard !persistenceFault else { throw KilnError.message("Release committed but previous resource cleanup is unconfirmed; runtime requires recovery") }
        return "Active \(name)@\(manifest.version) via 127.0.0.1:\(manifest.ingressPort!) (healthy; previous connections drained)"
    }
}


extension KilnRuntime {
    public func operationHistory() throws -> String {
        let directory = stateDirectory.appendingPathComponent("operations")
        guard FileManager.default.fileExists(atPath: directory.path) else { return "No recorded AI operations." }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" }
        let records = try files.map { try JSONDecoder().decode([String: String].self, from: Data(contentsOf: $0)) }
            .sorted { ($0["startedAt"] ?? "") > ($1["startedAt"] ?? "") }.prefix(50)
        return records.map { record in
            let state = record["state"] == "started" ? "unconfirmed (inspect state; do not blindly retry)" : record["state"] ?? "unknown"
            return [record["id"] ?? "", record["startedAt"] ?? "", record["operation"] ?? "", record["module"] ?? "", state].joined(separator: "  ")
        }.joined(separator: "\n")
    }

    public func performApprovedOperation(_ operation: String, name: String, fingerprint: String) async throws -> String {
        guard snapshot().first(where: { $0.id == name })?.generationFingerprint == fingerprint else {
            throw KilnError.message("Module changed since proposal; ask AI for a fresh proposal")
        }
        guard ["start", "stop", "restart", "rollback"].contains(operation) else {
            throw KilnError.message("Unsupported AI operation")
        }
        let directory = stateDirectory.appendingPathComponent("operations")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID().uuidString
        let path = directory.appendingPathComponent(id + ".json")
        var record = ["id": id, "source": "approved-ai", "operation": operation, "module": name,
                      "generation": fingerprint, "startedAt": Date().ISO8601Format(), "state": "started"]
        func persist(_ value: [String: String]) throws {
            try KilnStateFile.write(JSONEncoder().encode(value), to: path)
        }
        // Fail closed before any side effect if the operation receipt cannot be recorded.
        try persist(record)
        let result: String
        do {
            switch operation {
            case "start": result = try await start(name)
            case "stop": result = try await stop(name)
            case "rollback": result = try await rollback(name)
            default:
                result = try await restart(name)
            }
        } catch {
            record["state"] = "failed"
            record["finishedAt"] = Date().ISO8601Format()
            // Error text can contain application data; persist only the outcome.
            do { try persist(record) }
            catch { throw KilnError.message("Operation \(id) failed; outcome could not be recorded. Inspect module state before retrying.") }
            throw error
        }
        record["state"] = "succeeded"
        record["finishedAt"] = Date().ISO8601Format()
        do { try persist(record) }
        catch { throw KilnError.message("Operation \(id) completed but its outcome could not be recorded. Inspect module state before retrying.") }
        return result + "\nOperation: " + id
    }
}
