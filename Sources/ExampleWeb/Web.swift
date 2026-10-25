import Foundation
import KilnWeb

actor CounterModel {
    private var count = 0
    private var note = "State and HTML live on the server."
    func snapshot() -> (Int, String) { (count, note) }
    func increment() { count += 1 }
    func rename(_ text: String) { note = String(text.prefix(120)) }
}
actor CounterView: LiveView {
    let model: CounterModel
    let hub: LiveHub
    init(model: CounterModel, hub: LiveHub) { self.model = model; self.hub = hub }
    func render() async -> HTML {
        let (count, note) = await model.snapshot()
        return """
        <header><span>KILN / LIVE WEB</span><a href="/">Framework home</a></header>
        <h1>Server-rendered.<br>Live by default.</h1><p>Open this page in two tabs. Every change travels through a Swift server action and broadcasts to connected views.</p>
        <section><span class="label">SHARED COUNTER</span><strong id="count">\(count)</strong><button id="increment" data-kiln-click="increment">Increment on server ↗</button></section>
        <section><span class="label">LIVE MESSAGE</span><p id="note">\(note)</p><form data-kiln-submit="rename"><label for="message">Update the shared message</label><input id="message" name="message" maxlength="120" required><button>Broadcast update</button></form></section>
        <footer>Swift controllers · escaped HTML · WebSocket events · application-local pub/sub</footer>
        """
    }
    func handle(_ event: LiveEvent) async throws {
        switch event.name {
        case "increment": await model.increment()
        case "rename":
            guard let value = event.values["message"], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WebError(422) }
            await model.rename(value)
        default: throw WebError(400)
        }
        await hub.publish("counter")
    }
}
struct HomeController {
    static func index(_ request: WebRequest) -> WebResponse {
        .html("""
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="/assets/app.css"><title>Kiln Web</title></head><body><main><header>KILN / WEB FRAMEWORK</header><h1>Your application.<br>Rendered in Swift.</h1><p>A native HTTP and live-view foundation for independently deployed Kiln applications.</p><a class="button" href="/counter">Open the live demo ↗</a><section><h2>Controller and form action</h2><form method="post" action="/greet"><input type="hidden" name="_csrf" value="\(request.session.csrfToken)"><label for="name">Your name</label><input id="name" name="name" required><button>Render greeting</button></form></section></main></body></html>
        """)
    }
    static func greet(_ request: WebRequest) throws -> WebResponse {
        let name = try request.form()["name"] ?? "friend"
        return .html("<html lang=\"en\"><head><title>Greeting</title><link rel=\"stylesheet\" href=\"/assets/app.css\"></head><body><main><h1>Hello, \(name)</h1><a href=\"/\">Back</a></main></body></html>")
    }
}
@main struct ExampleWeb {
    static func main() throws {
        let args = CommandLine.arguments
        let port = ProcessInfo.processInfo.environment["KILN_PORT"].flatMap(Int.init) ?? args.firstIndex(of: "--port").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 18082
        let origin = args.firstIndex(of: "--origin").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "http://127.0.0.1:\(port)"
        let hub = LiveHub(), model = CounterModel()
        var router = WebRouter()
        try router.on("GET", "/", action: { HomeController.index($0) })
        try router.on("POST", "/greet", action: { try HomeController.greet($0) })
        try router.on("POST", "/counter/increment", action: { _ in
            await model.increment(); await hub.publish("counter"); return try .json(["updated": true])
        })
        try router.on("GET", "/health", action: { _ in try .json(["status": "ok"]) })
        try router.on("GET", "/hello/:name", action: { request in .html("<h1>Hello, \(request.parameters["name"] ?? "friend")</h1>") })
        try router.on("GET", "/assets/app.css", action: { _ in .init(contentType: "text/css; charset=utf-8", body: Data(css.utf8)) })
        try router.live("/counter", topics: ["counter"]) { _ in CounterView(model: model, hub: hub) }
        let application = try WebApplication(router: router, origin: origin, hub: hub, healthAuthority: "127.0.0.1:\(port)", layout: { page in
            """
            <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Kiln Live Web</title><link rel="stylesheet" href="/assets/app.css">\(page.client)</head><body>\(page.status)\(page.root)</body></html>
            """
        })
        let server = try WebServer(application: application, port: port)
        print("Kiln Web demo: \(origin) (worker port \(server.port))")
        try server.wait()
    }
    static let css = """
    :root{color-scheme:dark;--bg:#080c09;--panel:#111912;--text:#e3f0e6;--accent:#64f58c;--muted:#91aa99}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:17px/1.6 ui-sans-serif,system-ui,sans-serif}main{max-width:960px;margin:0 auto;padding:64px 32px}header{display:flex;justify-content:space-between;gap:24px;color:var(--accent);font:12px ui-monospace,monospace;letter-spacing:.12em}h1{font-size:clamp(40px,7vw,76px);line-height:1.04;font-weight:550;letter-spacing:-.055em;margin:64px 0 24px}p{color:var(--muted);max-width:670px}a{color:var(--accent)}section{border:1px solid #28382c;background:var(--panel);padding:32px;margin-top:32px;border-radius:12px}.label{font:12px ui-monospace,monospace;letter-spacing:.12em;color:var(--muted)}strong{display:block;font:72px ui-monospace,monospace;color:var(--accent);margin:12px 0}button,.button{display:inline-block;border:0;background:var(--accent);color:#071009;padding:12px 20px;border-radius:6px;font:600 15px system-ui;cursor:pointer;text-decoration:none}form{display:grid;gap:12px}input{background:var(--bg);color:var(--text);border:1px solid #425347;border-radius:6px;padding:12px;font:inherit}button{justify-self:start}footer{margin-top:48px;color:var(--muted);font-size:13px}#kiln-live-status{position:fixed;right:16px;bottom:8px;padding:6px 12px;border:1px solid #28382c;border-radius:20px;background:var(--bg);font-size:12px;z-index:1}a:focus-visible,button:focus-visible,input:focus-visible{outline:2px solid var(--accent);outline-offset:4px}
    """
}
