import Foundation

/// Template literals are trusted markup; interpolated strings are escaped for
/// HTML text/quoted attribute contexts. Never interpolate into scripts or CSS.
public struct HTML: Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public let rendered: String
    public init(stringLiteral value: String) { rendered = value }
    public init(stringInterpolation: StringInterpolation) { rendered = stringInterpolation.output }
    public struct StringInterpolation: StringInterpolationProtocol {
        var output = ""
        public init(literalCapacity: Int, interpolationCount: Int) { output.reserveCapacity(literalCapacity) }
        public mutating func appendLiteral(_ literal: String) { output += literal }
        public mutating func appendInterpolation(_ value: String) { output += HTML.escape(value) }
        public mutating func appendInterpolation(_ value: Int) { output += String(value) }
        public mutating func appendInterpolation(_ value: HTML) { output += value.rendered }
    }
    public static func join(_ fragments: [HTML]) -> HTML { HTML(stringLiteral: fragments.map(\.rendered).joined()) }
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
}
public struct BrowserSession: Sendable {
    public let id: String
    public let csrfToken: String
}
public struct WebRequest: Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let body: Data
    public var parameters: [String: String] = [:]
    public let session: BrowserSession
    public func form() throws -> [String: String] {
        guard headers["content-type"]?.split(separator: ";").first == "application/x-www-form-urlencoded",
              let value = String(data: body, encoding: .utf8) else { throw WebError(415) }
        return try Self.fields(value)
    }
    static func fields(_ value: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for pair in value.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  let text = (parts.count == 2 ? String(parts[1]) : "").replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  !key.isEmpty, key.utf8.count <= 128, text.utf8.count <= 8192,
                  result[key] == nil, result.count < 64 else { throw WebError(400) }
            result[key] = text
        }
        return result
    }
    static func target(_ uri: String) throws -> (String, [String: String]) {
        guard uri.utf8.count <= 8192, uri.hasPrefix("/"), !uri.hasPrefix("//"), !uri.contains("#") else { throw WebError(400) }
        let parts = uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0])
        guard let decoded = path.removingPercentEncoding, !decoded.contains("\\"),
              !path.lowercased().contains("%2f"), !path.lowercased().contains("%5c"),
              !decoded.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !decoded.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else { throw WebError(400) }
        return (decoded, parts.count > 1 ? try fields(String(parts[1])) : [:])
    }
}
public struct WebResponse: Sendable {
    public let status: Int
    public let contentType: String
    public let body: Data
    public var headers: [String: String]
    public init(status: Int = 200, contentType: String = "text/html; charset=utf-8", body: Data, headers: [String: String] = [:]) {
        self.status = status; self.contentType = contentType; self.body = body; self.headers = headers
    }
    public static func html(_ html: HTML, status: Int = 200) -> Self { Self(status: status, body: Data(html.rendered.utf8)) }
    public static func json<T: Encodable>(_ value: T, status: Int = 200) throws -> Self {
        Self(status: status, contentType: "application/json", body: try JSONEncoder().encode(value))
    }
    public static func redirect(_ path: String) throws -> Self {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\"), path.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }) else { throw WebError(400) }
        return Self(status: 303, body: Data(), headers: ["location": path])
    }
}
public struct WebError: Error, Sendable { public let status: Int; public init(_ status: Int) { self.status = status } }
public typealias WebAction = @Sendable (WebRequest) async throws -> WebResponse
/// Return a response to stop the pipeline, or nil to continue. App authentication
/// and authorization belong here and are rechecked on live events/renders.
public typealias WebMiddleware = @Sendable (WebRequest) async throws -> WebResponse?
public protocol LiveView: Sendable {
    func render() async throws -> HTML
    func handle(_ event: LiveEvent) async throws
}
public struct LiveEvent: Codable, Sendable {
    public let sequence: Int
    public let name: String
    public let values: [String: String]
    public let csrf: String
    public init(sequence: Int, name: String, values: [String: String] = [:], csrf: String) { self.sequence = sequence; self.name = name; self.values = values; self.csrf = csrf }
}
public struct WebRouter: Sendable {
    struct Route: Sendable { let method: String; let pattern: String; let action: WebAction?; let live: (@Sendable (WebRequest) async throws -> any LiveView)?; let topics: [String] }
    var routes: [Route] = []
    public var middleware: [WebMiddleware] = []
    public init() {}
    public mutating func on(_ method: String, _ path: String, action: @escaping WebAction) throws {
        try add(Route(method: method, pattern: path, action: action, live: nil, topics: []))
    }
    public mutating func live(_ path: String, topics: [String] = [], mount: @escaping @Sendable (WebRequest) async throws -> any LiveView) throws {
        guard topics.count <= 16, topics.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else { throw WebError(400) }
        try add(Route(method: "GET", pattern: path, action: nil, live: mount, topics: topics))
    }
    private mutating func add(_ route: Route) throws {
        guard ["GET", "POST", "PUT", "PATCH", "DELETE"].contains(route.method), route.pattern.hasPrefix("/"),
              !route.pattern.hasPrefix("/__kiln"), !route.pattern.contains("?"), !route.pattern.contains("%"),
              !routes.contains(where: { $0.method == route.method && Self.shape($0.pattern) == Self.shape(route.pattern) }) else { throw WebError(400) }
        _ = try WebRequest.target(route.pattern)
        let names = route.pattern.split(separator: "/").filter { $0.hasPrefix(":") }
        guard Set(names).count == names.count, names.allSatisfy({ (2...33).contains($0.count) && $0.dropFirst().allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) }) else { throw WebError(400) }
        routes.append(route)
    }
    private static func shape(_ path: String) -> [String] { path.split(separator: "/", omittingEmptySubsequences: false).map { $0.hasPrefix(":") ? ":" : String($0) } }
    func match(_ request: WebRequest) throws -> (Route, WebRequest) {
        let pieces = request.path.split(separator: "/", omittingEmptySubsequences: false)
        var pathExists = false
        // Static routes take precedence over parameterized routes.
        for route in routes.sorted(by: { $0.pattern.split(separator: "/").filter { $0.hasPrefix(":") }.count < $1.pattern.split(separator: "/").filter { $0.hasPrefix(":") }.count }) {
            let pattern = route.pattern.split(separator: "/", omittingEmptySubsequences: false)
            guard pattern.count == pieces.count else { continue }
            var params: [String: String] = [:]; var matches = true
            for (p, value) in zip(pattern, pieces) {
                if p.hasPrefix(":"), !value.isEmpty { params[String(p.dropFirst())] = String(value) }
                else if p != value { matches = false; break }
            }
            guard matches else { continue }; pathExists = true
            guard route.method == request.method || (request.method == "HEAD" && route.method == "GET") else { continue }
            var matched = request; matched.parameters = params; return (route, matched)
        }
        throw WebError(pathExists ? 405 : 404)
    }
    func authorize(_ request: WebRequest) async throws -> WebResponse? {
        for check in middleware { if let response = try await check(request) { return response } }
        return nil
    }
}
