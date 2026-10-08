import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KilnAI

/// URLProtocol supplies decoded HTTP body fragments, including the absence of
/// Content-Length that a chunked response presents to URLSession delegates.
private final class CompletionBodyProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let headers = path == "/declared-large" ? ["Content-Length": "9000000"] : ["Transfer-Encoding": "chunked"]
        let response = HTTPURLResponse(url: request.url!, statusCode: path == "/error" ? 500 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path == "/waiting" { return }
        if path == "/large" || path == "/declared-large" || path == "/error" {
            for _ in 0..<20 { client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 262144)) }
        } else {
            for piece in ["a", "bc", "def"] { client?.urlProtocol(self, didLoad: Data(piece.utf8)) }
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func completionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CompletionBodyProtocol.self]
    return configuration
}

@Test func aiCompletionEnforcesActualChunkedBodyLimit() async throws {
    let request = URLRequest(url: URL(string: "https://fixture.invalid/large")!)
    do {
        _ = try await BoundedCompletionHTTP.data(for: request, configuration: completionConfiguration())
        Issue.record("Unbounded chunked completion body was accepted")
    } catch { #expect(String(describing: error).contains("size limit")) }
    let valid = try await BoundedCompletionHTTP.data(for: URLRequest(url: URL(string: "https://fixture.invalid/valid")!), configuration: completionConfiguration())
    #expect(String(decoding: valid, as: UTF8.self) == "abcdef")
}

@Test func aiCompletionRejectsDeclaredOversizeAndErrorBodies() async throws {
    for (path, expected) in [("declared-large", "size limit"), ("error", "HTTP 500")] {
        do {
            _ = try await BoundedCompletionHTTP.data(for: URLRequest(url: URL(string: "https://fixture.invalid/" + path)!), configuration: completionConfiguration())
            Issue.record("Rejected HTTP response was accepted")
        } catch { #expect(String(describing: error).contains(expected)) }
    }
}

@Test func aiCompletionCancellationClosesWaitingTransport() async throws {
    let task = Task {
        try await BoundedCompletionHTTP.data(for: URLRequest(url: URL(string: "https://fixture.invalid/waiting")!), configuration: completionConfiguration())
    }
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled request returned success") }
    catch { #expect(error is CancellationError) }
}
