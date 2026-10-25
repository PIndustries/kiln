# KilnWeb: server-rendered applications and live views

KilnWeb is an optional Swift library for trusted application workers. It provides
HTTP routing, async controller actions, middleware, escaped HTML composition,
browser sessions, forms and server-rendered live views over WebSocket. It does
not run application code inside the supervisor. The demo is a separate executable.

This first milestone follows the HTTP-first, server-owned view model familiar
from Phoenix LiveView. It is not Phoenix wire compatible and does not claim
Phoenix feature parity. Updates currently replace the live HTML fragment; DOM
diffs, navigation, uploads, ORM integration, distributed state and production TLS
routing remain separate work.

## Run the example

```sh
swift build --jobs 2
.build/debug/kiln-example-web --port 18082
```

Open `http://127.0.0.1:18082/`. `/` demonstrates a controller-rendered page and a
normal POST form; `/hello/:name` demonstrates route parameters; `/counter` shows
server-owned interactive state. Open `/counter` in two tabs: increment or submit
a message in either, and both receive freshly rendered HTML. A separate HTTP
controller action also broadcasts through the same application-local hub.

`KILN_PORT` overrides the CLI port. `/health` is the application's health route.
Register the compiled executable with `app install MANIFEST`, then use
`app start APP/MODULE` and `app health APP/MODULE`, with a fixed loopback port and
health URL. It can update independently of the supervisor and other applications.
No bundle format is required. The preview example is `web-demo/live`.

Managed `app deploy` additionally requires an ingress port. The example supports
`--origin http://127.0.0.1:18085` to declare its stable browser-facing origin, while
Kiln supplies `KILN_PORT` from the release's health URL. For example:

```json
{
  "application": "web-demo",
  "name": "live",
  "version": "0.1.0",
  "executable": "/absolute/path/to/kiln-example-web",
  "arguments": ["--origin", "http://127.0.0.1:18085"],
  "healthURL": "http://127.0.0.1:18084/__kiln/health",
  "ingressPort": 18085
}
```

Use `app deploy MANIFEST` and open `http://127.0.0.1:18085/counter`. Subsequent
releases use the same ingress/public origin and a different worker health port.
`app rollback web-demo/live` uses the existing release lifecycle. Live browser
state is not durable across release changes; reload the page after deployment.

`WebApplication(..., healthAuthority: "127.0.0.1:18084")` explicitly enables the
read-only `/__kiln/health` worker probe for that loopback Host. It never invokes a
controller or mounts a view, and reports worker HTTP liveness, not model/database
readiness. This exception permits no other backend route or mutation and does
not weaken the public Origin/Host checks. The example configures it from its
worker port. This managed loopback ingress/upgrade/rollback path is integration
tested; public TLS/proxy termination remains separate work.

## Controllers, templates and middleware

```swift
import KilnWeb

struct GreetingController {
    static func show(_ request: WebRequest) -> WebResponse {
        let name = request.parameters["name"] ?? "friend"
        let heading: HTML = "<h1>Hello, \(name)</h1>"
        return .html("<main>\(heading)</main>")
    }
}

var router = WebRouter()
try router.on("GET", "/hello/:name") { GreetingController.show($0) }
let app = try WebApplication(router: router, origin: "http://127.0.0.1:18082")
let server = try WebServer(application: app, port: 18082)
try server.wait()
```

`HTML` interpolates strings as escaped HTML text or quoted attributes; nested
`HTML` fragments retain their markup. `HTML.join` composes lists of fragments.
Literal markup is trusted developer code. This is not a script/CSS/URL sanitizer:
never insert user strings into executable contexts or construct trusted HTML
from untrusted whole strings using `stringLiteral:`.

Actions can return HTML, typed JSON or a validated local 303 redirect. Requests
include decoded path parameters, unique query/form fields, headers, bounded body
and a server-issued browser session. Static paths precede parameter paths. HEAD
uses the GET route without sending the body. Unknown paths return 404; valid
paths with unsupported methods return 405 after the browser security checks.
Ambiguous duplicate parameters, encoded path separators and dot traversal fail.
Registered GET/HEAD actions must be read-only, including live mounting/rendering.

`router.middleware` runs before controller actions and live mounting, and is
rechecked before live events, renders and periodic connection checks. Return a
response to halt the HTTP pipeline; denying a connected view closes it. Resolve
current application authorization in middleware and at the model mutation
boundary. Kiln administrator/SSH permissions are not browser login credentials.
A browser session identifies an opaque client, not an authenticated person.

Normal mutations require the existing session cookie, exact configured Origin,
and CSRF token in `X-CSRF-Token` or URL-encoded `_csrf`. `request.form()` accepts
bounded unique URL-encoded fields; multipart/file uploads are unsupported.
Cookies are HttpOnly, SameSite=Strict and Secure for a configured HTTPS origin.
Cookie names default to an origin-derived namespace so separate local app ports
do not overwrite each other's cookies. Apps sharing one public origin must set
separate `cookieName` values explicitly. Sessions live in worker memory for 15
minutes; restart expires them. Use one canonical public `origin` with matching
Host and Origin headers; forwarded headers are not trusted automatically.

## Live views and broadcasts

Implement `LiveView` as an actor with `render()` and `handle(_:)`, then register:

```swift
let hub = LiveHub()
try router.live("/counter", topics: ["counter"]) { request in
    CounterView(model: model, hub: hub)
}
```

A GET first mounts the view and renders complete HTML. The small built-in browser
client then attaches to that same view using an unguessable page ticket bound to
its cookie and exact Origin. Route code chooses topic subscriptions; browsers
cannot subscribe to arbitrary topics. No application state is stored in HTML
apart from presentation and the browser's CSRF/page tokens.

Use `data-kiln-click="increment"` on a button and `data-kiln-submit="rename"` on a
form. The browser sends ordered events; the server invokes the view and returns
HTML. `await hub.publish("counter")` invalidates subscribed views, including
updates originating in a controller or another application task. Publication
is process-local invalidation, not durable messaging, shared storage, cross-node
replication or automatic access to another module's memory.

Customize the outer document using `WebApplication(..., layout: { page in ... })`.
Include `page.root`, `page.status` and `page.client` in the layout. Applications
own their stylesheets/assets. The example defaults to black/green and uses CSS
variables for colors. Stable field IDs preserve unsent form drafts and focus
across updates; after a form is sent its draft is cleared. Repeated fields and
file inputs are rejected by the first client protocol.

## Lifecycle and limits

Only one socket owns a mounted view at a time. Events have sequential IDs and
CSRF tokens; duplicate or out-of-order events close the connection. The sequence
is reserved before the application mutation, so an uncertain callback is never
automatically retried. Applications remain responsible for transactional model
changes and durable idempotency where needed. Renders must be read-only.

After disconnect, reconnect can reattach to the same worker's view for 60 seconds
while its browser session remains valid. The browser takes a fresh rendered
snapshot and never replays queued actions. A new page has 60 seconds to attach.
Expired entries are pruned during state access. Restart, deployment, expired
sessions and lost worker ownership require page reload; there is no persisted
live-view recovery or cluster handoff. The example counter model is deliberately
in-memory and resets when its worker restarts.

A worker bounds sessions at 512, live views at 256 and views per session at 8.
Request/event bodies are limited to 16 KiB, header processing to 16 KiB/64 fields,
rendered fragments to 512 KiB and responses/wire snapshots to 1 MiB. A connection
has a 32-message queue; overflow or a non-writable socket closes it so reconnect
can resynchronize. Events are never silently dropped and replayed. Fragmented or
binary WebSocket messages are unsupported and rejected. Periodic checks recheck
session/authorization and send WebSocket pings. HTTP connections have a ten-second
deadline, process one response and close. Application async work must cooperate
with cancellation; worker process supervision provides the outer failure boundary.

The initial listener binds only to loopback and does not terminate TLS. An
internet-facing deployment still needs tested TLS/proxy routing, edge admission,
authentication, operational sizing and its own application acceptance. CSP,
no-sniff, no-store and referrer headers are applied by the transport; exceptions
never serialize application error details.

## Validation

`WebFrameworkTests` covers templates, routing, forms, origin/session/CSRF boundaries,
connection fencing, duplicate mutation rejection and authorization rechecks.
`python3 scripts/web-framework-integration.py` uses a disposable real worker and
standard-library HTTP/WebSocket clients. It proves SSR, two-browser broadcasts,
controller-to-live events, escaping, reconnect, rejection paths and real Kiln
ingress deployment/upgrade/rollback. Both hosted
macOS and Linux validation run this integration suite.
