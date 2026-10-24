import Foundation
import Testing
@testable import KilnTelemetry
import KilnKit

@Test func realHostMetrics() async throws {
    let sampler = KilnTelemetry(diskPath: FileManager.default.temporaryDirectory.path)
    let first = await sampler.sample()
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


private final class TelemetryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private var collections = 0
    func now() -> ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
    func collect() -> [Int32: ProcessMetrics] {
        lock.withLock {
            collections += 1
            // Simulate a collector taking longer than the cache lifetime.
            instant = instant.advanced(by: .seconds(2))
            return [42: ProcessMetrics(cpuPercent: 0, residentBytes: UInt64(collections))]
        }
    }
}

@Test func telemetryCacheStartsAfterCollectionAndExpiresOnMonotonicTime() async {
    let clock = TelemetryClock()
    let sampler = KilnTelemetry(diskPath: FileManager.default.temporaryDirectory.path,
                                cacheNow: { clock.now() }, processSampler: { clock.collect() })
    let first = await sampler.sample()
    #expect(first.processes[42]?.residentBytes == 1)
    let shared = await sampler.sample()
    #expect(shared.processes[42]?.residentBytes == 1)
    clock.advance(.milliseconds(899))
    let stillShared = await sampler.sample()
    #expect(stillShared.processes[42]?.residentBytes == 1)
    clock.advance(.milliseconds(1))
    let refreshed = await sampler.sample()
    #expect(refreshed.processes[42]?.residentBytes == 2)
}
