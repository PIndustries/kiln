import Foundation

/// A release contract, independent of its management interface or application protocols.
public struct ApplicationManifest: Codable, Sendable {
    public let application: String
    public let name: String
    public let version: String
    public var executable: String
    public let arguments: [String]
    public let healthURL: String?

    public init(application: String = "default", name: String, version: String, executable: String, arguments: [String] = [], healthURL: String? = nil) {
        self.application = application; self.name = name; self.version = version; self.executable = executable
        self.arguments = arguments; self.healthURL = healthURL
    }

    public func validate() throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        for value in [application, name, version] {
            guard !value.isEmpty, value.count <= 80, value != ".", value != "..",
                  value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                throw KilnError.message("Invalid application name or version")
            }
        }
        guard executable.hasPrefix("/") else { throw KilnError.message("Executable must be an absolute path") }
        if let healthURL {
            guard let url = URL(string: healthURL), url.scheme == "http", url.host == "127.0.0.1" else {
                throw KilnError.message("Prototype health checks must use http://127.0.0.1")
            }
        }
    }
}

public enum KilnError: Error, CustomStringConvertible {
    case message(String)
    public var description: String { switch self { case .message(let text): return text } }
}

/// Transport-independent observation; process state does not imply application health.
public struct ModuleSnapshot: Sendable, Equatable {
    public let application: String
    public let name: String
    public let version: String
    public let state: String
    public let pid: Int32?
    public var id: String { "\(application)/\(name)" }
    public init(application: String, name: String, version: String, state: String, pid: Int32?) {
        self.application = application; self.name = name; self.version = version
        self.state = state; self.pid = pid
    }
}

public struct ProcessMetrics: Sendable {
    public let cpuPercent: Double
    public let residentBytes: UInt64
    public init(cpuPercent: Double, residentBytes: UInt64) { self.cpuPercent = cpuPercent; self.residentBytes = residentBytes }
}
public struct HostMetrics: Sendable {
    public let timestamp: Date
    public let hostname: String
    public let supervisorPID: Int32
    public let cpuPercent: Double?
    public let cores: Int
    public let memoryResident: UInt64?
    public let memoryTotal: UInt64
    public let diskFree: UInt64?
    public let diskTotal: UInt64?
    public let uptime: TimeInterval
    public let load: [Double]
    public let processes: [Int32:ProcessMetrics]
    public init(timestamp: Date, hostname: String, supervisorPID: Int32, cpuPercent: Double?, cores: Int, memoryResident: UInt64?, memoryTotal: UInt64, diskFree: UInt64?, diskTotal: UInt64?, uptime: TimeInterval, load: [Double], processes: [Int32:ProcessMetrics]) {
        self.timestamp = timestamp; self.hostname = hostname; self.supervisorPID = supervisorPID; self.cpuPercent = cpuPercent; self.cores = cores
        self.memoryResident = memoryResident; self.memoryTotal = memoryTotal; self.diskFree = diskFree; self.diskTotal = diskTotal
        self.uptime = uptime; self.load = load; self.processes = processes
    }
    public static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "unavailable" }
        return String(format: "%.1f GiB", Double(value)/1_073_741_824)
    }
    public var summary: String {
        "Host: \(hostname)\nSample: \(timestamp.ISO8601Format())\nCPU: \(cpuPercent.map { String(format: "%.1f%%", $0) } ?? "warming up") / \(cores) cores\nMemory resident: \(Self.bytes(memoryResident)) / \(Self.bytes(memoryTotal))\nDisk free: \(Self.bytes(diskFree)) / \(Self.bytes(diskTotal))\nUptime: \(Int(uptime)/86400)d \(Int(uptime)/3600%24)h \(Int(uptime)/60%60)m\nLoad (1/5/15m): \(load.map { String(format: "%.2f",$0) }.joined(separator: " "))"
    }
}
public struct Observation: Sendable {
    public let modules: [ModuleSnapshot]
    public let host: HostMetrics
    public init(modules: [ModuleSnapshot], host: HostMetrics) { self.modules = modules; self.host = host }
}
