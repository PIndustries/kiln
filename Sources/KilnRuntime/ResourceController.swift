import Foundation
import KilnKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Cgroup v2 ownership is separate from PID ownership. Only generation groups
/// recorded in this private state directory can be reconciled or killed.
enum ResourceController {
    struct Record: Codable {
        let id: String
        let root: String
        let module: String
        let version: String
        let limits: ModuleResourceLimits
    }

    static func prepare(required: Bool = false) throws -> URL? {
        guard let configured = ProcessInfo.processInfo.environment["KILN_CGROUP_ROOT"], !configured.isEmpty else {
            if required { throw KilnError.message("Resource limits require Linux cgroup v2 delegation and KILN_CGROUP_ROOT") }
            return nil
        }
        #if os(Linux)
        let current = try currentGroup()
        var root: URL
        if configured == "auto" {
            root = current.lastPathComponent == "kiln-control" ? current.deletingLastPathComponent() : current
        } else { root = URL(fileURLWithPath: configured) }
        root = try validateRoot(root.path)
        let control = root.appendingPathComponent("kiln-control")
        guard current.path == root.path || current.path == control.path else {
            throw KilnError.message("Configured cgroup must be the supervisor's delegated cgroup, not an unrelated host group")
        }
        let controllers = Set(try read(root, "cgroup.controllers").split(separator: " ").map(String.init))
        guard Set(["cpu", "memory", "pids"]).isSubset(of: controllers) else {
            throw KilnError.message("Delegated cgroup lacks cpu, memory or pids controllers")
        }
        try makeDirectory(control)
        if current.path == root.path { try write(control, "cgroup.procs", String(getpid())) }
        try write(root, "cgroup.subtree_control", "+cpu +memory +pids")
        let workers = root.appendingPathComponent("kiln-workers")
        try makeDirectory(workers)
        try write(workers, "cgroup.subtree_control", "+cpu +memory +pids")
        return root
        #else
        throw KilnError.message("Hard module resource limits require Linux cgroup v2; macOS enforcement is unsupported")
        #endif
    }

    static func ensureSupported(_ limits: ModuleResourceLimits?) throws {
        guard let limits else { return }
        try limits.validate()
        #if !os(Linux)
        throw KilnError.message("Hard module resource limits require Linux cgroup v2; macOS enforcement is unsupported")
        #endif
    }

    static func create(id: String, root: String, state: URL, manifest: ApplicationManifest) throws -> Record {
        guard let limits = manifest.resources else { throw KilnError.message("Missing resource limits") }
        try ensureSupported(limits)
        let rootURL = try validateRoot(root)
        let record = Record(id: id, root: rootURL.path, module: "\(manifest.application)/\(manifest.name)", version: manifest.version, limits: limits)
        try validate(record)
        let ledger = state.appendingPathComponent("resource-ledger")
        try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Persist group intent BEFORE mkdir or worker launch. An interrupted create
        // is safe to reconcile; no executable is allowed to run before attachment.
        try KilnStateFile.write(JSONEncoder().encode(record), to: ledger.appendingPathComponent(id + ".json"))
        let directory = group(record)
        do {
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw KilnError.message("Resource generation already exists") }
            try makeDirectory(directory)
            try write(directory, "memory.max", String(limits.memoryBytes))
            try write(directory, "memory.swap.max", "0")
            try write(directory, "memory.oom.group", "1")
            try write(directory, "cpu.max", "\(limits.cpuMillis * 100) 100000")
            try write(directory, "pids.max", String(limits.maxProcesses))
            guard FileManager.default.isWritableFile(atPath: directory.appendingPathComponent("cgroup.kill").path) else {
                throw KilnError.message("Kernel cgroup.kill is unavailable; descendant cleanup cannot be guaranteed")
            }
            try verify(record)
        } catch {
            try? removeEmptyTree(directory)
            throw error
        }
        return record
    }

    static func attach(root: String, id: String) throws {
        let rootURL = try validateRoot(root)
        guard UUID(uuidString: id) != nil else { throw KilnError.message("Invalid resource generation") }
        let directory = rootURL.appendingPathComponent("kiln-workers/kiln-" + id)
        try write(directory, "cgroup.procs", "0")
        #if os(Linux)
        guard try currentGroup().path == directory.path else { throw KilnError.message("Worker cgroup attachment was not confirmed") }
        #endif
    }

    static func finish(_ record: Record, state: URL) throws {
        try validate(record)
        let directory = group(record)
        if FileManager.default.fileExists(atPath: directory.path) {
            // cgroup.kill handles concurrent forks and all descendants atomically.
            try write(directory, "cgroup.kill", "1")
            var empty = false
            for _ in 0..<100 {
                if try !read(directory, "cgroup.events").split(separator: "\n").contains("populated 1") { empty = true; break }
                usleep(50_000)
            }
            guard empty else { throw KilnError.message("Resource descendants have not exited; refusing to discard ownership") }
            // Every diagnostic step is best-effort, including mkdir. A full disk
            // or obstructed report path must not strand an empty owned group.
            if let report = try? observation(record, active: false) {
                writeDiagnostic(report, module: record.module, state: state)
            }
            try removeEmptyTree(directory)
        }
        let marker = state.appendingPathComponent("resource-ledger/" + record.id + ".json")
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
    }

    static func writeDiagnostic(_ report: String, module: String, state: URL) {
        do {
            let destination = state.appendingPathComponent("resource-reports/" + module + ".txt")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try KilnStateFile.write(Data(report.utf8), to: destination)
        } catch {
            // Inspection may be unavailable; ownership cleanup remains mandatory.
        }
    }

    static func reconcile(state: URL) throws {
        let ledger = state.appendingPathComponent("resource-ledger")
        let files = FileManager.default.fileExists(atPath: ledger.path)
            ? try FileManager.default.contentsOfDirectory(at: ledger, includingPropertiesForKeys: nil) : []
        let records = try files.filter { $0.pathExtension == "json" }.map { file in
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
            guard file.lastPathComponent == record.id + ".json" else { throw KilnError.message("Resource ownership filename does not match its generation") }
            return record
        }
        let root = try prepare(required: !records.isEmpty)
        for record in records {
            guard record.root == root?.path else { throw KilnError.message("Resource ledger belongs to a different delegated cgroup; refusing to affect unrelated host groups") }
            try finish(record, state: state)
        }
    }

    static func finish(id: String, state: URL) throws {
        let path = state.appendingPathComponent("resource-ledger/" + id + ".json")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: path))
        guard record.id == id else { throw KilnError.message("Resource ownership generation does not match") }
        let root = try prepare(required: true)
        guard record.root == root?.path else { throw KilnError.message("Resource ledger delegation changed") }
        try finish(record, state: state)
    }

    static func status(id: String, state: URL) throws -> String {
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: state.appendingPathComponent("resource-ledger/" + id + ".json")))
        guard record.id == id else { throw KilnError.message("Resource ownership generation does not match") }
        return try observation(record, active: true)
    }

    private static func observation(_ record: Record, active: Bool) throws -> String {
        try validate(record)
        let directory = group(record)
        var lines = ["Module: \(record.module)@\(record.version)", "Enforcement: Linux cgroup v2 (\(active ? "active" : "exited"))", "Generation: \(record.id)", "Cgroup: \(directory.path)"]
        for key in ["memory.max", "memory.swap.max", "memory.current", "memory.peak", "memory.events", "cpu.max", "cpu.stat", "pids.max", "pids.current", "pids.events"] {
            let value = (try? read(directory, key)) ?? "unavailable"
            lines.append("\(key): \(value.replacingOccurrences(of: "\n", with: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private static func verify(_ record: Record) throws {
        let directory = group(record)
        guard try read(directory, "memory.max") == String(record.limits.memoryBytes),
              try read(directory, "memory.swap.max") == "0",
              try read(directory, "memory.oom.group") == "1",
              try read(directory, "cpu.max") == "\(record.limits.cpuMillis * 100) 100000",
              try read(directory, "pids.max") == String(record.limits.maxProcesses) else {
            throw KilnError.message("Kernel resource controls did not match requested limits")
        }
    }

    private static func validate(_ record: Record) throws {
        guard UUID(uuidString: record.id) != nil else { throw KilnError.message("Invalid resource ownership record") }
        _ = try validateRoot(record.root)
        try record.limits.validate()
        let parts = record.module.split(separator: "/")
        guard parts.count == 2 else { throw KilnError.message("Invalid resource module") }
        try ApplicationManifest(application: String(parts[0]), name: String(parts[1]), version: record.version, executable: "/unused").validate()
    }

    private static func validateRoot(_ path: String) throws -> URL {
        #if os(Linux)
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix("/sys/fs/cgroup/"), url.path != "/sys/fs/cgroup/",
              FileManager.default.fileExists(atPath: url.appendingPathComponent("cgroup.controllers").path) else {
            throw KilnError.message("Resource root must be an existing delegated cgroup v2 below /sys/fs/cgroup")
        }
        return url
        #else
        throw KilnError.message("Hard module resource limits require Linux cgroup v2; macOS enforcement is unsupported")
        #endif
    }

    #if os(Linux)
    private static func currentGroup() throws -> URL {
        let membership = try String(contentsOfFile: "/proc/self/cgroup", encoding: .utf8)
        guard let line = membership.split(separator: "\n").first(where: { $0.hasPrefix("0::/") }) else { throw KilnError.message("Unified cgroup v2 is unavailable") }
        return URL(fileURLWithPath: "/sys/fs/cgroup" + line.dropFirst(3)).standardizedFileURL
    }
    #endif

    private static func group(_ record: Record) -> URL {
        URL(fileURLWithPath: record.root).appendingPathComponent("kiln-workers/kiln-" + record.id)
    }

    private static func makeDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw KilnError.message("Cannot create delegated resource group; check cgroup permissions") }
    }

    private static func read(_ directory: URL, _ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func write(_ directory: URL, _ name: String, _ value: String) throws {
        let descriptor = open(directory.appendingPathComponent(name).path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw KilnError.message("Cannot open cgroup control \(name); check delegation and kernel support") }
        defer { close(descriptor) }
        let bytes = Array((value + "\n").utf8)
        let written = bytes.withUnsafeBytes { buffer in
            #if canImport(Darwin)
            Darwin.write(descriptor, buffer.baseAddress!, buffer.count)
            #else
            Glibc.write(descriptor, buffer.baseAddress!, buffer.count)
            #endif
        }
        guard written == bytes.count else { throw KilnError.message("Cannot set cgroup control \(name); check delegation and controller availability") }
    }

    private static func removeEmptyTree(_ directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) {
            if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { try removeEmptyTree(child) }
        }
        guard rmdir(directory.path) == 0 else { throw KilnError.message("Resource group remains populated; refusing to discard ownership") }
    }
}
