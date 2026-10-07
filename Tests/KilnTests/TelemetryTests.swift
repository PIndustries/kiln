import Foundation
import Testing
import KilnTelemetry

@Test func realHostMetricsAndSharedSampling() async throws {
    let sampler = KilnTelemetry(diskPath: FileManager.default.temporaryDirectory.path)
    let first = await sampler.sample()
    let cached = await sampler.sample()
    #expect(first.timestamp == cached.timestamp)
    #expect(first.cores > 0)
    #expect(first.memoryTotal > 0)
    #expect(first.uptime > 0)
    #expect(first.diskTotal != nil)
    #expect(first.processes[ProcessInfo.processInfo.processIdentifier]?.residentBytes ?? 0 > 0)
    try await Task.sleep(for: .seconds(1))
    let next = await sampler.sample()
    #expect(next.timestamp > first.timestamp)
    #expect(next.cpuPercent != nil)
    #expect((0...100).contains(next.cpuPercent ?? -1))
}
