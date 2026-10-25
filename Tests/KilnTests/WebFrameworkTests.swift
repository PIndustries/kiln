import Foundation
import Testing
@testable import KilnWeb

private let webOrigin = "http://127.0.0.1:18082"
private let webHeaders = ["host": "127.0.0.1:18082"]
private func responseText(_ response: WebResponse) -> String { String(decoding: response.body, as: UTF8.self) }
private func browserHeaders(_ response: WebResponse) throws -> [String: String] {
    let cookie = try #require(response.headers["set-cookie"]?.split(separator: ";").first)
    return webHeaders.merging(["cookie": String(cookie), "origin": webOrigin]) { _, new in new }
}
private actor WebCounter: LiveView {
    var count = 0
    func render() -> HTML { "<p>Count \(count)</p>" }
    func handle(_ event: LiveEvent) throws {
        guard event.name == "increment" else { throw WebError(400) }
        count += 1
    }
}

@Test func htmlInterpolationEscapesTextAndAllowsTypedComponents() {
    let value = "<script>alert('x')</script> & \"quote\""
    let component: HTML = "<span>\(value)</span>"
    let page: HTML = "<main>\(component) \(42)</main>"
    #expect(page.rendered == "<main><span>&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; &quot;quote&quot;</span> 42</main>")
    #expect(HTML.join([component, component]).rendered == component.rendered + component.rendered)
}
@Test func mvcRoutesDecodeParametersDistinguishMethodsAndRejectAmbiguousInput() async throws {
    var router = WebRouter()
    try router.on("GET", "/hello/:name") { request in .html("<h1>\(request.parameters["name"] ?? "")</h1>") }
    try router.on("GET", "/hello/world") { _ in .html("<p>static</p>") }
    let app = try WebApplication(router: router, origin: webOrigin)
    let staticPage = await app.respond(method: "GET", uri: "/hello/world", headers: webHeaders)
    #expect(responseText(staticPage).contains("static"))
    #expect(responseText(await app.respond(method: "GET", uri: "/hello/%3Cimg%3E", headers: webHeaders)) == "<h1>&lt;img&gt;</h1>")
    #expect(await app.respond(method: "POST", uri: "/hello/world", headers: webHeaders).status == 403)
    for target in ["//evil.test/path", "/hello/%2fworld", "/hello/..", "/hello/world?a=1&a=2", "/hello/%00", "/hello/%ZZ"] {
        #expect(await app.respond(method: "GET", uri: target, headers: webHeaders).status == 400)
    }
    #expect(await app.respond(method: "PUT", uri: "/unknown", headers: webHeaders).status == 403)
    #expect(await app.respond(method: "GET", uri: "/unknown", headers: webHeaders).status == 404)
    #expect(await app.respond(method: "GET", uri: "/", headers: ["host": "evil.test"]).status == 403)
    #expect(throws: WebError.self) { try router.on("GET", "/hello/:other") { _ in .html("bad") } }
}
@Test func browserFormsRequireOriginalSessionOriginAndCsrf() async throws {
    var router = WebRouter()
    try router.on("GET", "/") { request in .html("\(request.session.csrfToken)") }
    try router.on("POST", "/form") { request in .html("\(try request.form()["name"] ?? "")") }
    let app = try WebApplication(router: router, origin: webOrigin)
    let page = await app.respond(method: "GET", uri: "/", headers: webHeaders)
    var headers = try browserHeaders(page)
    headers["content-type"] = "application/x-www-form-urlencoded"
    let body = Data("_csrf=\(responseText(page))&name=%3Cscript%3E".utf8)
    #expect(responseText(await app.respond(method: "POST", uri: "/form", headers: headers, body: body)) == "&lt;script&gt;")
    #expect(await app.respond(method: "DELETE", uri: "/form", headers: headers, body: body).status == 405)
    var wrong = headers; wrong["origin"] = "http://evil.test"
    #expect(await app.respond(method: "POST", uri: "/form", headers: wrong, body: body).status == 403)
    #expect(await app.respond(method: "POST", uri: "/form", headers: headers, body: Data("name=unsafe".utf8)).status == 403)
    wrong = headers; wrong["cookie"] = "kiln_web=forged"
    #expect(await app.respond(method: "POST", uri: "/form", headers: wrong, body: body).status == 403)
    #expect(await app.respond(method: "POST", uri: "/form", headers: headers, body: Data(repeating: 1, count: 16385)).status == 413)
    #expect(page.headers["set-cookie"]?.contains("HttpOnly; SameSite=Strict") == true)
}
@Test func liveViewsRestoreServerStateWithoutReplayingEventsAndFenceConnectionLeases() async throws {
    var router = WebRouter()
    try router.live("/counter") { _ in WebCounter() }
    let app = try WebApplication(router: router, origin: webOrigin)
    let page = await app.respond(method: "GET", uri: "/counter", headers: webHeaders)
    #expect(responseText(page).contains("Count 0"))
    let headers = try browserHeaders(page)
    let cookie = try #require(try WebApplication.cookie(headers, name: app.cookieName))
    let ticket = try #require(responseText(page).components(separatedBy: "data-ticket=\"").dropFirst().first?.components(separatedBy: "\"").first)
    let path = "/__kiln/live/" + ticket
    let mount = try await app.claim(uri: path, headers: headers)
    let event = LiveEvent(sequence: 1, name: "increment", csrf: mount.request.session.csrfToken)
    let updated = try await app.snapshot(mount, event: JSONEncoder().encode(event))
    #expect(String(decoding: updated, as: UTF8.self).contains("Count 1"))
    do { _ = try await app.snapshot(mount, event: JSONEncoder().encode(event)); Issue.record("Replayed duplicate mutation") } catch {}
    do { _ = try await app.claim(uri: path, headers: headers); Issue.record("Duplicate active owner") } catch {}
    await app.state.disconnect(mount)
    let resumed = try await app.claim(uri: path, headers: headers)
    #expect(String(decoding: try await app.snapshot(resumed), as: UTF8.self).contains("Count 1"))
    do { _ = try await app.snapshot(mount); Issue.record("Old lease retained authority") } catch {}
    await app.state.disconnect(mount) // Stale cleanup cannot release the new owner.
    #expect(try await app.state.validate(resumed) == 1)
    await app.state.disconnect(resumed)
    var stolen = headers; stolen["cookie"] = "kiln_web=other"
    do { _ = try await app.claim(uri: path, headers: stolen); Issue.record("Cross-browser mount") } catch {}
    stolen = headers; stolen["origin"] = "http://evil.test"
    do { _ = try await app.claim(uri: path, headers: stolen); Issue.record("Cross-origin mount") } catch {}
    #expect(cookie == resumed.request.session.id)
}
private actor WebGate {
    var allowed = true
    func deny() { allowed = false }
    func check() -> Bool { allowed }
}
@Test func liveMiddlewareRechecksAuthorizationAfterConnectionAndErrorsAreRedacted() async throws {
    let gate = WebGate()
    var router = WebRouter()
    router.middleware = [{ _ in await gate.check() ? nil : WebResponse(status: 403, body: Data()) }]
    try router.live("/counter") { _ in WebCounter() }
    let app = try WebApplication(router: router, origin: webOrigin)
    let page = await app.respond(method: "GET", uri: "/counter", headers: webHeaders)
    let ticket = try #require(responseText(page).components(separatedBy: "data-ticket=\"").dropFirst().first?.components(separatedBy: "\"").first)
    let mount = try await app.claim(uri: "/__kiln/live/" + ticket, headers: browserHeaders(page))
    await gate.deny()
    do { _ = try await app.snapshot(mount); Issue.record("Revoked authorization retained rendering") } catch {}
    var broken = WebRouter()
    try broken.on("GET", "/") { _ in throw NSError(domain: "PRIVATE_DATABASE_CREDENTIAL", code: 42) }
    let failed = await (try WebApplication(router: broken, origin: webOrigin)).respond(method: "GET", uri: "/", headers: webHeaders)
    #expect(failed.status == 500 && !responseText(failed).contains("PRIVATE_DATABASE"))
}

@Test func liveCapacityAndCsrfAreBoundedWithoutAllocatingSessionsForInvalidPosts() async throws {
    var router = WebRouter()
    try router.live("/counter") { _ in WebCounter() }
    let app = try WebApplication(router: router, origin: webOrigin)
    for _ in 0..<520 {
        #expect(await app.respond(method: "POST", uri: "/counter", headers: webHeaders.merging(["origin": webOrigin, "cookie": "forged=value"]) { _, new in new }).status == 403)
    }
    let first = await app.respond(method: "GET", uri: "/counter", headers: webHeaders)
    #expect(first.status == 200)
    let headers = try browserHeaders(first)
    for _ in 1..<8 { #expect(await app.respond(method: "GET", uri: "/counter", headers: headers).status == 200) }
    #expect(await app.respond(method: "GET", uri: "/counter", headers: headers).status == 503)
    let ticket = try #require(responseText(first).components(separatedBy: "data-ticket=\"").dropFirst().first?.components(separatedBy: "\"").first)
    let mount = try await app.claim(uri: "/__kiln/live/" + ticket, headers: headers)
    let forged = LiveEvent(sequence: 1, name: "increment", csrf: "forged")
    do { _ = try await app.snapshot(mount, event: JSONEncoder().encode(forged)); Issue.record("Forged event reached model") } catch {}
    #expect(try await app.state.validate(mount) == 0)
    #expect(String(decoding: try await app.snapshot(mount), as: UTF8.self).contains("Count 0"))
}
private actor AmbiguousWebCounter: LiveView {
    var count = 0
    func render() -> HTML { "<p>Count \(count)</p>" }
    func handle(_ event: LiveEvent) throws { count += 1; throw WebError(500) }
}
@Test func uncertainApplicationMutationIsNeverReplayedAfterReconnect() async throws {
    var router = WebRouter()
    try router.live("/counter") { _ in AmbiguousWebCounter() }
    let app = try WebApplication(router: router, origin: webOrigin)
    let first = await app.respond(method: "GET", uri: "/counter", headers: webHeaders)
    let headers = try browserHeaders(first)
    let ticket = try #require(responseText(first).components(separatedBy: "data-ticket=\"").dropFirst().first?.components(separatedBy: "\"").first)
    let path = "/__kiln/live/" + ticket
    let mount = try await app.claim(uri: path, headers: headers)
    let event = LiveEvent(sequence: 1, name: "increment", csrf: mount.request.session.csrfToken)
    do { _ = try await app.snapshot(mount, event: JSONEncoder().encode(event)); Issue.record("Expected application failure") } catch {}
    await app.state.disconnect(mount)
    let resumed = try await app.claim(uri: path, headers: headers)
    do { _ = try await app.snapshot(resumed, event: JSONEncoder().encode(event)); Issue.record("Replayed uncertain mutation") } catch {}
    #expect(String(decoding: try await app.snapshot(resumed), as: UTF8.self).contains("Count 1"))
}
@Test func webAppsNamespaceCookiesAndAllowCustomLayoutsAndSafeRedirects() async throws {
    var router = WebRouter()
    try router.live("/counter") { _ in WebCounter() }
    let app = try WebApplication(router: router, origin: webOrigin, layout: { page in "<html><head><title>My app</title>\(page.client)</head><body>\(page.status)\(page.root)</body></html>" })
    let other = try WebApplication(router: router, origin: "http://127.0.0.1:18083")
    #expect(app.cookieName != other.cookieName)
    #expect(responseText(await app.respond(method: "GET", uri: "/counter", headers: webHeaders)).contains("<title>My app</title>"))
    #expect(try WebResponse.redirect("/done").status == 303)
    for target in ["//evil.test", "javascript:alert(1)", "/\\evil.test", "/\r\nx-header: injected"] {
        #expect(throws: WebError.self) { try WebResponse.redirect(target) }
    }
}

@Test func managedWebWorkerHealthDoesNotBypassPublicOriginOrInvokeControllers() async throws {
    var router = WebRouter()
    try router.on("GET", "/private") { _ in .html("private controller") }
    let app = try WebApplication(router: router, origin: webOrigin, healthAuthority: "127.0.0.1:18084")
    let backend = ["host": "127.0.0.1:18084"]
    #expect(await app.respond(method: "GET", uri: "/__kiln/health", headers: backend).status == 200)
    #expect(await app.respond(method: "HEAD", uri: "/__kiln/health", headers: backend).status == 200)
    #expect(await app.respond(method: "POST", uri: "/__kiln/health", headers: backend).status == 403)
    #expect(await app.respond(method: "GET", uri: "/private", headers: backend).status == 403)
    #expect(await app.respond(method: "GET", uri: "/__kiln/health?private=1", headers: backend).status == 403)
    #expect(await app.respond(method: "GET", uri: "/private", headers: webHeaders).status == 200)
    #expect(throws: WebError.self) { try WebApplication(router: router, origin: webOrigin, healthAuthority: "remote.invalid:80") }
}

@Test func developmentReloadIsOptInOriginBoundAndChangesWithWorkerInstance() async throws {
    var router = WebRouter()
    try router.live("/counter") { _ in WebCounter() }
    try router.on("GET", "/") { _ in .html("<body>Home</body>") }
    let ordinary = try WebApplication(router: router, origin: webOrigin)
    #expect(await ordinary.respond(method: "GET", uri: "/__kiln/instance", headers: webHeaders).status == 404)
    let first = try WebApplication(router: router, origin: webOrigin, developmentReload: true)
    let second = try WebApplication(router: router, origin: webOrigin, developmentReload: true)
    let a = await first.respond(method: "GET", uri: "/__kiln/instance", headers: webHeaders)
    let b = await second.respond(method: "GET", uri: "/__kiln/instance", headers: webHeaders)
    #expect(a.status == 200 && a.body != b.body)
    #expect(responseText(await first.respond(method: "GET", uri: "/", headers: webHeaders)).contains("/__kiln/development.js"))
    #expect(!responseText(await ordinary.respond(method: "GET", uri: "/", headers: webHeaders)).contains("/__kiln/development.js"))
    #expect(await first.respond(method: "GET", uri: "/__kiln/instance", headers: ["host":"evil.test"]).status == 403)
    #expect(await first.respond(method: "POST", uri: "/__kiln/instance", headers: webHeaders).status == 403)
    #expect(responseText(await first.respond(method: "GET", uri: "/counter", headers: webHeaders)).contains("data-development-reload=\"true\""))
}
