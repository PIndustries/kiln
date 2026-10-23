import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KilnAI

private final class ResponsesHeaderProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "responses-header.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let headers = path == "/wrong-type" ? ["Content-Type": "text/html"] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = path == "/html" ? "<html>not a response</html>" : path == "/interrupted" ? "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n" : "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"OK\"}]}]}}\n\n"
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@Test func chatGPTAbsentContentTypeStillRequiresACompletedBoundedResponsesStream() async throws {
    let options = URLSessionConfiguration.ephemeral
    options.protocolClasses = [ResponsesHeaderProtocol.self]
    let client = OpenAIResponsesClient()
    func request(_ path: String) -> URLRequest { URLRequest(url: URL(string: "https://responses-header.invalid" + path)!) }
    let answer = try await client.streamAttempt(request: request("/valid"), configuration: options, allowMissingContentType: true) { _ in }
    #expect(answer.content == "OK")
    for path in ["/html", "/interrupted", "/wrong-type"] {
        do {
            _ = try await client.streamAttempt(request: request(path), configuration: options, allowMissingContentType: true) { _ in }
            Issue.record("Invalid response accepted: \(path)")
        } catch { #expect(error is AIError) }
    }
    // API-key providers keep strict MIME enforcement even for otherwise valid SSE.
    do {
        _ = try await client.streamAttempt(request: request("/valid"), configuration: options) { _ in }
        Issue.record("Absent MIME accepted without ChatGPT allowance")
    } catch { #expect(error is AIError) }
}
