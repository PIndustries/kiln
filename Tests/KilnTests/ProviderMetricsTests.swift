import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KilnAI

private actor MetricAttempts {
    var value = 0
    func next() -> Int { value += 1; return value }
}
private func metricRejection(_ code: String, delay: String = "0") -> ProviderFailure {
    var error = ProviderFailure(response: HTTPURLResponse(url: URL(string: "https://secret.invalid/private")!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": delay])!)
    _ = error.append(try! JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": "private-prompt-credential"]]))
    return error
}
@Test func providerMetricsSeparateAttemptsRetriesAndSuccessWithoutLabels() async throws {
    let metrics = AIProviderMetrics(); let attempts = MetricAttempts()
    let _: String = try await ProviderRetry.run(metrics: metrics, emit: { _ in }, sleep: {}) {
        switch await attempts.next() {
        case 1: throw metricRejection("capacity_exceeded")
        case 2: throw metricRejection("rate_limit_exceeded")
        default: return "private-prompt-credential"
        }
    }
    let snapshot = await metrics.snapshot()
    #expect(snapshot.started == 3 && snapshot.active == 0 && snapshot.retries == 2)
    #expect(snapshot.outcomes["capacity"] == 1)
    #expect(snapshot.outcomes["rateLimited"] == 1)
    #expect(snapshot.outcomes["completed"] == 1)
    #expect(snapshot.outcomes.count == AIProviderMetrics.Outcome.allCases.count)
    let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    #expect(!encoded.contains("private") && !encoded.contains("secret.invalid"))
}
@Test func providerMetricsClassifyTimeoutCancellationAndInvalidResponse() async throws {
    let metrics = AIProviderMetrics()
    for code in [URLError.timedOut, .networkConnectionLost, .cancelled] {
        do {
            let _: String = try await metrics.measure { throw ProviderTransportFailure(URLError(code)) }
        } catch { }
    }
    do { let _: String = try await metrics.measure { throw AIError.message("private-malformed-payload") } } catch { }
    let value = await metrics.snapshot()
    #expect(value.started == 4 && value.active == 0)
    for outcome in ["timeout", "transport", "cancelled", "invalidResponse"] { #expect(value.outcomes[outcome] == 1) }
}
@Test func providerMetricsCancelledBackoffDoesNotInventAnAttempt() async throws {
    let metrics = AIProviderMetrics()
    do {
        let _: String = try await ProviderRetry.run(metrics: metrics, emit: { _ in }, sleep: { throw CancellationError() }) {
            throw metricRejection("capacity_exceeded", delay: "30")
        }
    } catch { #expect(error is CancellationError) }
    let snapshot = await metrics.snapshot()
    #expect(snapshot.started == 1 && snapshot.retries == 0 && snapshot.active == 0)
    #expect(snapshot.cancelledBackoffs == 1 && snapshot.outcomes["capacity"] == 1)
}

@Test func providerMetricsDoNotGuessUnknown429Category() {
    #expect(metricRejection("unrecognized-private-code").outcome == .rejected)
    #expect(metricRejection("quota_exceeded").outcome == .quota)
}
