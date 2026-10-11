import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KilnAI

private func rejection(_ code: String, delay: String = "30") -> ProviderFailure {
    var failure = ProviderFailure(response: HTTPURLResponse(url: URL(string: "https://fixture.invalid")!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": delay])!)
    _ = failure.append(try! JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": "SECRET\u{1b}[2J"]]))
    return failure
}
private actor Attempts {
    var count = 0
    func next() -> Int { count += 1; return count }
    func value() -> Int { count }
}
@Test func providerErrorsAreActionableAndRedacted() {
    let capacity = rejection("capacity_exceeded")
    #expect(capacity.explanation().contains("Backend capacity is full"))
    #expect(capacity.explanation().contains("30 seconds"))
    #expect(!capacity.explanation().contains("SECRET"))
    #expect(!capacity.explanation().contains("\u{1b}"))
    #expect(rejection("quota_exceeded").retrySeconds == nil)
    #expect(rejection("unknown_secret_code").retrySeconds == nil)
    #expect(!rejection("unknown_secret_code").explanation().contains("unknown_secret_code"))
    #expect(rejection("capacity_exceeded", delay: "61").retrySeconds == nil)
    #expect(rejection("capacity_exceeded", delay: "-1").retrySeconds == nil)
    #expect(rejection("capacity_exceeded", delay: "SECRET").retrySeconds == nil)
    #expect(ProviderFailure.retryDelay("Thu, 01 Jan 1970 00:00:30 GMT", now: Date(timeIntervalSince1970: 0)) == 30)
    var large = rejection("capacity_exceeded")
    let accepted = large.append(Data(repeating: 65, count: 16385))
    #expect(!accepted)
}
@Test func providerRetriesOnlyTypedPreGenerationCapacityAndAreBounded() async throws {
    let counter = Attempts()
    do {
        let _: String = try await ProviderRetry.run(emit: { _ in }, sleep: {}) {
            _ = await counter.next(); throw rejection("capacity_exceeded", delay: "0")
        }
        Issue.record("Exhausted retry was accepted")
    } catch { #expect(error is ProviderFailure) }
    #expect(await counter.value() == 3)
    for code in ["quota_exceeded", "unknown"] {
        let denied = Attempts()
        do {
            let _: String = try await ProviderRetry.run(emit: { _ in }, sleep: {}) {
                _ = await denied.next(); throw rejection(code)
            }
        } catch { #expect(error is ProviderFailure) }
        #expect(await denied.value() == 1)
    }
    let success = Attempts()
    let value: String = try await ProviderRetry.run(emit: { _ in }, sleep: {}) {
        if await success.next() == 1 { throw rejection("rate_limit_exceeded", delay: "0") }; return "OK"
    }
    #expect(value == "OK")
    #expect(await success.value() == 2)
}
@Test func providerRetryWaitCanBeCancelled() async throws {
    let counter = Attempts()
    let task = Task {
        let _: String = try await ProviderRetry.run(emit: { _ in }) {
            _ = await counter.next(); throw rejection("capacity_exceeded")
        }
    }
    try await Task.sleep(for: .milliseconds(50)); task.cancel()
    do { try await task.value; Issue.record("Cancelled retry continued") }
    catch { #expect(error is CancellationError) }
    #expect(await counter.value() == 1)
}

private final class PartialStreamProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url!.path != "/partial" {
            let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Transfer-Encoding": "chunked", "Retry-After": "30"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let body = request.url!.path == "/oversized" ? Data(repeating: 65, count: 32768) : Data("{\"error\":{\"code\":\"capacity_exceeded\",\"message\":\"SECRET\"}}".utf8)
            let midpoint = body.count / 2
            client?.urlProtocol(self, didLoad: body.prefix(midpoint))
            client?.urlProtocol(self, didLoad: body.suffix(body.count - midpoint))
            client?.urlProtocolDidFinishLoading(self); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"Partial\"}}]}\n\n".utf8))
        client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
    }
    override func stopLoading() {}
}
@Test func providerNeverRetriesAPartialStream() async throws {
    let counter = Attempts()
    let metrics = AIProviderMetrics()
    do {
        let _: AIMessage = try await ProviderRetry.run(metrics: metrics, emit: { _ in }, sleep: {}) {
            _ = await counter.next()
            let options = URLSessionConfiguration.ephemeral; options.protocolClasses = [PartialStreamProtocol.self]
            return try await ErebineClient().streamAttempt(request: URLRequest(url: URL(string: "https://fixture.invalid/partial")!), configuration: options, emit: { _ in })
        }
        Issue.record("Interrupted stream was accepted")
    } catch { #expect(!(error is ProviderFailure)) }
    #expect(await counter.value() == 1)
    let snapshot = await metrics.snapshot()
    #expect(snapshot.outcomes["transport"] == 1 && snapshot.active == 0)
}

@Test func providerDelegatesDecodeBoundedRejectionWithoutLeakingBody() async throws {
    for path in ["capacity", "oversized"] {
        for streaming in [false, true] {
            let options = URLSessionConfiguration.ephemeral; options.protocolClasses = [PartialStreamProtocol.self]
            let request = URLRequest(url: URL(string: "https://fixture.invalid/" + path)!)
            do {
                if streaming { _ = try await ErebineClient().streamAttempt(request: request, configuration: options, emit: { _ in }) }
                else { _ = try await BoundedCompletionHTTP.data(for: request, configuration: options) }
                Issue.record("Provider rejection accepted")
            } catch {
                let text = String(describing: error)
                #expect(text.contains("HTTP 429"))
                #expect(!text.contains("SECRET"))
                #expect(text.contains("30 seconds"))
                if path == "capacity" { #expect(text.contains("Backend capacity is full")) }
                if path == "oversized", let failure = error as? ProviderFailure { #expect(failure.retrySeconds == nil) }
            }
        }
    }
}
