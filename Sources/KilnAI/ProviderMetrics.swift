import Foundation

/// Fixed-cardinality transport counters. No request, account, endpoint or model labels.
public actor AIProviderMetrics {
    public enum Outcome: String, Codable, CaseIterable, Sendable {
        case completed, capacity, rateLimited, quota, authentication, rejected, timeout, cancelled, transport, invalidResponse
    }
    public struct Snapshot: Codable, Sendable {
        public let started: UInt64
        public let active: UInt64
        public let outcomes: [String: UInt64]
        public let totalMilliseconds: UInt64
        public let maximumMilliseconds: UInt64
        public let retries: UInt64
        public let cancelledBackoffs: UInt64
        public var summary: String {
            let counts = Outcome.allCases.map { "\($0.rawValue)=\(outcomes[$0.rawValue] ?? 0)" }.joined(separator: " ")
            return "AI provider transport (since process start)\nAttempts: \(started); active: \(active); retries: \(retries); cancelled waits: \(cancelledBackoffs)\n\(counts)\nElapsed total: \(totalMilliseconds) ms; maximum: \(maximumMilliseconds) ms\nTransport completion is not a tool-operation outcome; use ai operations for approved operations."
        }
    }
    private var started: UInt64 = 0
    private var active: UInt64 = 0
    private var counts: [Outcome: UInt64] = [:]
    private var total: UInt64 = 0
    private var maximum: UInt64 = 0
    private var retries: UInt64 = 0
    private var cancelledBackoffs: UInt64 = 0
    public init() {}
    private func adding(_ a: UInt64, _ b: UInt64 = 1) -> UInt64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : value
    }
    func recordBackoffCancellation() { cancelledBackoffs = adding(cancelledBackoffs) }
    public func snapshot() -> Snapshot {
        Snapshot(started: started, active: active, outcomes: Dictionary(uniqueKeysWithValues: Outcome.allCases.map { ($0.rawValue, counts[$0] ?? 0) }), totalMilliseconds: total, maximumMilliseconds: maximum, retries: retries, cancelledBackoffs: cancelledBackoffs)
    }
    func measure<T: Sendable>(isRetry: Bool = false, _ operation: @Sendable () async throws -> T) async throws -> T {
        if isRetry { retries = adding(retries) }
        started = adding(started); active = adding(active)
        let clock = ContinuousClock(); let start = clock.now
        do {
            let value = try await operation()
            finish(.completed, elapsed: start.duration(to: clock.now))
            return value
        } catch {
            let outcome: Outcome
            if error is CancellationError || Task.isCancelled { outcome = .cancelled }
            else if let failure = error as? ProviderFailure { outcome = failure.outcome }
            else if let failure = error as? ProviderTransportFailure { outcome = failure.outcome }
            else { outcome = .invalidResponse }
            finish(outcome, elapsed: start.duration(to: clock.now))
            throw error
        }
    }
    private func finish(_ outcome: Outcome, elapsed: Duration) {
        active -= 1; counts[outcome] = adding(counts[outcome] ?? 0)
        let parts = elapsed.components
        let milliseconds = max(0, Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15)
        let value = milliseconds >= Double(UInt64.max) ? UInt64.max : UInt64(milliseconds)
        total = adding(total, value); maximum = max(maximum, value)
    }
}

/// Retain only a safe category, never URLSession's request URL or error body.
struct ProviderTransportFailure: Error, CustomStringConvertible {
    let outcome: AIProviderMetrics.Outcome
    init(_ error: Error) {
        let code = (error as NSError).code
        let isURL = (error as NSError).domain == NSURLErrorDomain
        outcome = isURL && code == NSURLErrorTimedOut ? .timeout : isURL && code == NSURLErrorCancelled ? .cancelled : .transport
    }
    var description: String {
        switch outcome {
        case .timeout: "Provider request timed out; no automatic retry"
        case .cancelled: "Provider request cancelled"
        default: "Provider transport failed; no automatic retry"
        }
    }
}
