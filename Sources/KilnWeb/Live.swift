import Foundation
import Crypto

/// Process-local, app-owned notifications. Topics are chosen by route code,
/// never by a browser. This is invalidation pub/sub, not durable job delivery.
public actor LiveHub {
    private struct Subscriber { let topics: Set<String>; let refresh: @Sendable () -> Void }
    private var subscribers: [String: Subscriber] = [:]
    public init() {}
    func join(_ id: String, topics: [String], refresh: @escaping @Sendable () -> Void) { subscribers[id] = Subscriber(topics: Set(topics), refresh: refresh) }
    func leave(_ id: String) { subscribers.removeValue(forKey: id) }
    public func publish(_ topic: String) { for subscriber in subscribers.values where subscriber.topics.contains(topic) { subscriber.refresh() } }
}
struct LiveMount: Sendable {
    let ticket: String
    let lease: String
    let request: WebRequest
    let view: any LiveView
    let topics: [String]
}
actor BrowserState {
    struct Session { let browser: BrowserSession; let expires: Date }
    struct Page { let request: WebRequest; let view: any LiveView; let topics: [String]; var lease: String?; var expires: Date; var sequence = 0 }
    private var sessions: [String: Session] = [:]
    private var pages: [String: Page] = [:]
    func prune() {
        let now = Date()
        sessions = sessions.filter { $0.value.expires > now }
        pages = pages.filter { sessions[$0.value.request.session.id] != nil && ($0.value.lease != nil || $0.value.expires > now) }
    }
    func session(_ cookie: String?, create: Bool = true) throws -> (BrowserSession, Bool) {
        prune()
        if let cookie, let existing = sessions[cookie] { return (existing.browser, false) }
        guard create else { throw WebError(403) }
        guard sessions.count < 512 else { throw WebError(503) }
        let browser = BrowserSession(id: UUID().uuidString.lowercased(), csrfToken: UUID().uuidString.lowercased())
        sessions[browser.id] = Session(browser: browser, expires: Date().addingTimeInterval(900))
        return (browser, true)
    }
    func mount(request: WebRequest, view: any LiveView, topics: [String]) throws -> String {
        prune()
        guard pages.count < 256, pages.values.filter({ $0.request.session.id == request.session.id }).count < 8 else { throw WebError(503) }
        let ticket = UUID().uuidString.lowercased()
        pages[ticket] = Page(request: request, view: view, topics: topics, expires: Date().addingTimeInterval(60))
        return ticket
    }
    func available(ticket: String, cookie: String?) throws -> WebRequest {
        prune()
        guard let page = pages[ticket], page.request.session.id == cookie, page.lease == nil else { throw WebError(403) }
        return page.request
    }
    func claim(ticket: String, cookie: String?) throws -> LiveMount {
        let request = try available(ticket: ticket, cookie: cookie)
        let lease = UUID().uuidString.lowercased()
        pages[ticket]?.lease = lease
        let page = pages[ticket]!
        return LiveMount(ticket: ticket, lease: lease, request: request, view: page.view, topics: page.topics)
    }
    func disconnect(_ mount: LiveMount) {
        guard pages[mount.ticket]?.lease == mount.lease else { return }
        pages[mount.ticket]?.lease = nil; pages[mount.ticket]?.expires = Date().addingTimeInterval(60)
    }
    func validate(_ mount: LiveMount, event: LiveEvent? = nil) throws -> Int {
        prune()
        guard var page = pages[mount.ticket], page.lease == mount.lease else { throw WebError(403) }
        if let event {
            guard event.sequence > 0, event.sequence <= 1_000_000_000, event.sequence == page.sequence + 1,
                  event.csrf == page.request.session.csrfToken, !event.name.isEmpty, event.name.utf8.count <= 64,
                  event.name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_:".contains($0)) }),
                  event.values.count <= 64, event.values.allSatisfy({ $0.key.utf8.count <= 128 && $0.value.utf8.count <= 2048 }) else { throw WebError(400) }
            // Reserve before application mutation. A failed/ambiguous event is
            // never automatically replayed, including after reconnect.
            page.sequence = event.sequence; pages[mount.ticket] = page
        }
        return page.sequence
    }
}
/// Compose a layout around these typed fragments; retain root and client to
/// preserve the live protocol. Applications own their titles, assets and theme.
public struct LivePage: Sendable {
    public let root: HTML
    public let client: HTML = "<script src=\"/__kiln/live.js\" defer></script>"
    public let status: HTML = "<p id=\"kiln-live-status\" role=\"status\">Connecting live view…</p>"
    init(content: HTML, ticket: String, csrf: String, instance: String, developmentReload: Bool) {
        root = "<main id=\"kiln-live\" data-ticket=\"\(ticket)\" data-csrf=\"\(csrf)\" data-instance=\"\(instance)\" data-development-reload=\"\(developmentReload ? "true" : "false")\">\(content)</main>"
    }
}
public final class WebApplication: Sendable {
    let router: WebRouter
    public let hub: LiveHub
    let state = BrowserState()
    public let origin: String
    public let cookieName: String
    let authority: String
    let secure: Bool
    let healthAuthority: String?
    let developmentReload: Bool
    let instance = UUID().uuidString.lowercased()
    let layout: @Sendable (LivePage) -> HTML
    public init(router: WebRouter, origin: String, hub: LiveHub = LiveHub(), healthAuthority: String? = nil, developmentReload: Bool = false, cookieName: String? = nil, layout: @escaping @Sendable (LivePage) -> HTML = WebApplication.defaultLayout) throws {
        guard let url = URL(string: origin), let scheme = url.scheme, ["http", "https"].contains(scheme), let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty,
              let authority = URLComponents(string: origin)?.host, authority == host else { throw WebError(400) }
        let name = cookieName ?? "kiln_web_" + SHA256.hash(data: Data(origin.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        guard !name.isEmpty, name.count <= 64, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }) else { throw WebError(400) }
        if let healthAuthority {
            guard let health = URL(string: "http://" + healthAuthority), health.host == "127.0.0.1" || health.host == "[::1]",
                  let port = health.port, (1...65535).contains(port), health.path.isEmpty, health.user == nil, health.password == nil,
                  health.query == nil, health.fragment == nil else { throw WebError(400) }
        }
        self.healthAuthority = healthAuthority; self.developmentReload = developmentReload
        self.cookieName = String(name)
        self.origin = origin; self.authority = String(origin.dropFirst(scheme.count + 3)); self.secure = scheme == "https"
        self.router = router; self.hub = hub; self.layout = layout
    }
    public static func defaultLayout(_ page: LivePage) -> HTML {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Kiln Live</title>\(page.client)</head><body>\(page.status)\(page.root)</body></html>
        """
    }
    func checkHeaders(_ headers: [String: String], webSocket: Bool = false) throws {
        guard headers["host"] == authority else { throw WebError(403) }
        if webSocket { guard headers["origin"] == origin else { throw WebError(403) } }
    }
    static func cookie(_ headers: [String: String], name: String) throws -> String? {
        let cookies = (headers["cookie"] ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false) }
        let matches = cookies.filter { $0.first == Substring(name) }
        guard matches.count <= 1 else { throw WebError(400) }
        return matches.first.flatMap { $0.count == 2 ? String($0[1]) : nil }
    }
    func upgradeRequest(uri: String, headers: [String: String]) async throws -> WebRequest {
        try checkHeaders(headers, webSocket: true)
        let (path, query) = try WebRequest.target(uri)
        guard query.isEmpty, path.hasPrefix("/__kiln/live/"), UUID(uuidString: String(path.dropFirst(13))) != nil else { throw WebError(403) }
        let request = try await state.available(ticket: String(path.dropFirst(13)), cookie: Self.cookie(headers, name: cookieName))
        if try await router.authorize(request) != nil { throw WebError(403) }
        return request
    }
    func claim(uri: String, headers: [String: String]) async throws -> LiveMount {
        _ = try await upgradeRequest(uri: uri, headers: headers)
        return try await state.claim(ticket: String(uri.dropFirst(13)), cookie: Self.cookie(headers, name: cookieName))
    }
    func snapshot(_ mount: LiveMount, event: Data? = nil) async throws -> Data {
        if try await router.authorize(mount.request) != nil { throw WebError(403) }
        if let event {
            let decoded = try JSONDecoder().decode(LiveEvent.self, from: event)
            _ = try await state.validate(mount, event: decoded)
            try await mount.view.handle(decoded)
        }
        let html = try await mount.view.render()
        guard html.rendered.utf8.count <= 524288 else { throw WebError(500) }
        let sequence = try await state.validate(mount)
        return try JSONEncoder().encode(LiveSnapshot(version: 1, sequence: sequence, html: html.rendered))
    }
    private struct LiveSnapshot: Encodable { let version: Int; let sequence: Int; let html: String }
    public func respond(method: String, uri: String, headers: [String: String], body: Data = Data()) async -> WebResponse {
        do {
            // Explicit read-only loopback worker liveness, separate from the
            // public ingress origin. It never mounts a view or invokes an action.
            if let healthAuthority, headers["host"] == healthAuthority, uri == "/__kiln/health", ["GET", "HEAD"].contains(method), body.isEmpty {
                return try .json(["status": "ok", "scope": "web-worker-liveness"])
            }
            try checkHeaders(headers)
            guard body.count <= 16384 else { throw WebError(413) }
            let (path, query) = try WebRequest.target(uri)
            if developmentReload, path == "/__kiln/instance", ["GET", "HEAD"].contains(method), query.isEmpty {
                return try .json(["instance": instance])
            }
            if developmentReload, path == "/__kiln/development.js", ["GET", "HEAD"].contains(method), query.isEmpty {
                return WebResponse(contentType: "text/javascript; charset=utf-8", body: Data(developmentClient.utf8))
            }
            if path == "/__kiln/live.js", ["GET", "HEAD"].contains(method) {
                return WebResponse(contentType: "text/javascript; charset=utf-8", body: Data(Self.browserClient.utf8))
            }
            let cookie = try Self.cookie(headers, name: cookieName)
            let safe = ["GET", "HEAD"].contains(method)
            if !safe, headers["origin"] != origin { throw WebError(403) }
            let (browser, created) = try await state.session(cookie, create: safe)
            let request = WebRequest(method: method, path: path, query: query, headers: headers, body: body, session: browser)
            if !["GET", "HEAD"].contains(method) {
                guard !created, headers["origin"] == origin else { throw WebError(403) }
                let token = headers["x-csrf-token"] ?? (try? request.form()["_csrf"])
                guard token == browser.csrfToken else { throw WebError(403) }
            }
            let (route, matched) = try router.match(request)
            var response: WebResponse
            if let stopped = try await router.authorize(matched) { response = stopped }
            else if let action = route.action { response = try await action(matched) }
            else if let mount = route.live {
                let view = try await mount(matched)
                let initial = try await view.render()
                guard initial.rendered.utf8.count <= 524288 else { throw WebError(500) }
                let ticket = try await state.mount(request: matched, view: view, topics: route.topics)
                let html = layout(LivePage(content: initial, ticket: ticket, csrf: browser.csrfToken, instance: instance, developmentReload: developmentReload))
                response = .html(html)
            } else { throw WebError(404) }
            if developmentReload, ["GET", "HEAD"].contains(method), (200..<300).contains(response.status), response.contentType.lowercased().hasPrefix("text/html") {
                let script = "<script src=\"/__kiln/development.js\" defer></script>"
                let html = String(decoding: response.body, as: UTF8.self)
                let injected: String
                if let end = html.range(of: "</body>", options: .caseInsensitive) {
                    injected = String(html[..<end.lowerBound]) + script + String(html[end.lowerBound...])
                } else { injected = html + script }
                response = WebResponse(status: response.status, contentType: response.contentType, body: Data(injected.utf8), headers: response.headers)
            }
            if created { response.headers["set-cookie"] = "\(cookieName)=\(browser.id); Path=/; HttpOnly; SameSite=Strict; Max-Age=900" + (secure ? "; Secure" : "") }
            return response
        } catch let error as WebError { return WebResponse(status: error.status, contentType: "text/plain; charset=utf-8", body: Data("HTTP \(error.status)".utf8)) }
        catch { return WebResponse(status: 500, contentType: "text/plain; charset=utf-8", body: Data("Internal server error".utf8)) }
    }
}
