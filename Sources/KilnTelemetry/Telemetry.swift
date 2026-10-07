import Foundation
import KilnKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Shared, rate-limited sampler. No credentials, command lines or environment are collected.
public actor KilnTelemetry {
    private var cached: HostMetrics?
    private var lastTicks: (UInt64, UInt64)?
    private let diskPath: String
    public init(diskPath: String) { self.diskPath = diskPath }
    public func sample() -> HostMetrics {
        if let cached, Date().timeIntervalSince(cached.timestamp) < 0.9 { return cached }
        var cpu: Double?
        var memoryResident: UInt64?
        #if canImport(Darwin)
        let hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        if result == KERN_SUCCESS {
            let ticks = load.cpu_ticks
            let idle = UInt64(ticks.2)
            let total = UInt64(ticks.0) + UInt64(ticks.1) + idle + UInt64(ticks.3)
            if let previous = lastTicks, total > previous.0, idle >= previous.1 {
                cpu = 100 * (1 - Double(idle - previous.1) / Double(total - previous.0))
            }
            lastTicks = (total, idle)
        }
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(hostPort, HOST_VM_INFO64, $0, &vmCount) }
        }
        var pageSize: vm_size_t = 0
        if vmResult == KERN_SUCCESS, host_page_size(hostPort, &pageSize) == KERN_SUCCESS {
            memoryResident = (UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * UInt64(pageSize)
        }
        #else
        if let raw = try? String(contentsOfFile: "/proc/stat", encoding: .utf8), let line = raw.split(separator: "\n").first {
            let values = line.split(separator: " ").dropFirst().compactMap { UInt64($0) }
            if values.count >= 4 {
                let total = values.prefix(8).reduce(0,+), idle = values[3] + (values.count > 4 ? values[4] : 0)
                if let previous = lastTicks, total > previous.0, idle >= previous.1 { cpu = 100 * (1 - Double(idle-previous.1)/Double(total-previous.0)) }
                lastTicks = (total,idle)
            }
        }
        if let raw = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8) {
            let fields = Dictionary(uniqueKeysWithValues: raw.split(separator: "\n").compactMap { line -> (String,UInt64)? in
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                guard parts.count > 1, let value = UInt64(parts[1]) else { return nil }
                return (String(parts[0]),value*1024)
            })
            if let total = fields["MemTotal:"], let available = fields["MemAvailable:"] { memoryResident = total-available }
        }
        #endif
        var loads = [Double](repeating: 0, count: 3)
        let validLoad = getloadavg(&loads, 3) == 3
        let disk = try? FileManager.default.attributesOfFileSystem(forPath: diskPath)
        let metrics = HostMetrics(timestamp: Date(), hostname: ProcessInfo.processInfo.hostName, supervisorPID: ProcessInfo.processInfo.processIdentifier,
            cpuPercent: cpu.map { min(100,max(0,$0)) }, cores: ProcessInfo.processInfo.activeProcessorCount,
            memoryResident: memoryResident, memoryTotal: ProcessInfo.processInfo.physicalMemory,
            diskFree: (disk?[.systemFreeSize] as? NSNumber)?.uint64Value,
            diskTotal: (disk?[.systemSize] as? NSNumber)?.uint64Value,
            uptime: ProcessInfo.processInfo.systemUptime, load: validLoad ? loads : [], processes: processMetrics())
        cached = metrics
        return metrics
    }
    private func processMetrics() -> [Int32: ProcessMetrics] {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,pcpu=,rss="]
        process.environment = ["LC_ALL":"C", "PATH":"/usr/bin:/bin"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [:] }
            var values: [Int32:ProcessMetrics] = [:]
            for line in String(decoding: data,as: UTF8.self).split(separator: "\n") {
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                if parts.count == 3, let pid = Int32(parts[0]), let cpu = Double(parts[1]), let rss = UInt64(parts[2]) {
                    values[pid] = ProcessMetrics(cpuPercent: cpu, residentBytes: rss*1024)
                }
            }
            return values
        } catch { return [:] }
    }
}
