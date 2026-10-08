import Foundation

/// Kernel-enforced limits for a trusted Linux worker and its descendants.
/// CPU uses millicores: 1000 is one core. PID limits also count threads.
public struct ModuleResourceLimits: Codable, Sendable, Equatable {
    public let memoryBytes: Int64
    public let cpuMillis: Int
    public let maxProcesses: Int

    public init(memoryBytes: Int64, cpuMillis: Int, maxProcesses: Int) {
        self.memoryBytes = memoryBytes; self.cpuMillis = cpuMillis; self.maxProcesses = maxProcesses
    }

    public func validate() throws {
        guard (67_108_864...1_099_511_627_776).contains(memoryBytes), memoryBytes % 65_536 == 0,
              (10...64_000).contains(cpuMillis), (8...4096).contains(maxProcesses) else {
            throw KilnError.message("Resource limits require memoryBytes 64 MiB...1 TiB in 64 KiB increments, cpuMillis 10...64000, and maxProcesses 8...4096 (including threads)")
        }
    }
}
