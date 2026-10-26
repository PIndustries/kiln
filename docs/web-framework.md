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

## AI development preview

On macOS, an administrator can register one Swift application source file for
Kiln AI to edit and automatically publish to a local development ingress. This is
a development grant for that exact app, not a production-operation approval or
unrestricted shell/repository access. Ordinary start/stop/restart/rollback tools
still use approvals. Background tasks and non-administrators have no coding tools.

Build the example, `kiln-web-builder` and `kiln-web-runtime` first. Export an
immutable snapshot of the trusted SDK into a new directory:

```sh
python3 scripts/export-web-sdk.py --build-dir .build/arm64-apple-macosx/debug \
  --snapshot-dir /absolute/dev/sdk/revision-1 --output /absolute/dev/sdk.json
```

The exporter only copies already-built objects, module interfaces, C headers and
two trusted helpers. It does not execute package code. Without `--snapshot-dir`,
the recipe references the checkout's build directory and later rebuilds can
invalidate it. The administrator must explicitly export/register a new SDK when
upgrading the framework; AI cannot modify that configuration.

Copy `Sources/ExampleWeb/Web.swift` into a separate development workspace. Install
and start an ordinary web app with a stable ingress, then register a private JSON
file using `web register /absolute/dev/project.json`:

```json
{
  "schemaVersion": 1,
  "module": "web-demo/live",
  "source": "/absolute/dev/source/App.swift",
  "root": "/absolute/dev/source",
  "sdk": "/absolute/dev/sdk.json",
  "publicOrigin": "http://127.0.0.1:18085",
  "ingressPort": 18085,
  "workerPorts": [18084, 18086],
  "autoPublish": true
}
```

`root` explicitly opts in a dedicated codebase directory with `App.swift` as its
entry point. Keep SDK/configuration and other private files outside this root.
Re-export the SDK with the current builder before enabling a root: the recipe
must declare `projectFiles: true`. Omitting root preserves the existing one-file
grant and does not implicitly grant access to neighboring files.

The installed module and ingress must match; Vault-bound apps are excluded.
Source must be owned by the current OS user, UTF-8, at most 64 KiB and not writable
by other users. `web projects`, `web source APP/MODULE [OFFSET]` and
`web changes APP/MODULE` inspect the grant, paginated source and durable receipts.
The selected AI provider receives source pages just as it receives other tool
results. Registration explicitly grants that source access.

In Kiln AI, ask “Change the heading of web-demo/live to Hello from Kiln.” The AI
lists registered projects, reads the current source and requests 1–8 exact unique
text replacements. Only one write attempt runs per turn. The controller compiles
in a private job with the pinned SDK, then deploys a candidate on the alternate
worker port. It checks generation, current identity and provider context before
deploying and rechecks authorization after readiness, before activating ingress.
A successful deployment atomically saves the registered source. Failed builds
return bounded diagnostics and leave both live release and source unchanged.

No edited source executes in the supervisor. The compiler has no network and can
write only its job directory; SwiftPM, manifests, dependency downloads and package
plugins never run. Compilation has a 120-second deadline, 64 KiB diagnostic limit
and process-group cancellation. Each release uses a digest-checking sandbox
launcher: edited native code gets its own data directory, assigned loopback
listener and system runtime libraries. Outside files, subprocesses, outbound
networking and inherited provider credentials are denied. This first isolated
coding path requires macOS and fails closed on other operating systems.

`developmentReload: true` on `WebApplication` (the example's `--development` flag)
adds a same-origin external script to successful HTML pages. It checks the worker
instance once per second and reloads after a healthy release switch, including
ordinary controller pages. Failed builds leave the instance unchanged. Live event
broadcasts remain immediate and separate from compilation/reload. A code reload
resets in-memory demo state and unsaved browser input; it does not replay events.

State retains up to 8 projects, 2 concurrent builds and 32 development jobs,
including source before/after, compiled executable, diagnostics and receipts.
Active and rollback releases reference these retained artifacts: do not delete
them blindly. A crash or uncertain publish/source-write outcome is recorded for
inspection and never automatically replayed or rolled back. `active-source-pending`
means a release activated before the registered source commit; reconcile its
receipt, active release and job source before making another change. Project
snapshots and local Git commits retain all files, including creates/deletes.
Dependency changes, remote Git hosting and production publishing remain outside
this development grant. Portable bundles remain deferred.

`WebDevelopmentTests` covers source grants, invalid edits, SDK drift, failed-build
invariance and foreground tool gating. `web-sandbox-integration.py` compiles and
runs a real confined probe against disposable outside files, process/network
attempts and environment markers. `web-development-integration.py` runs real
OpenSSH, a credential-free Ollama protocol fixture, source tools, native isolated
compilation, managed deploy and invalid-build recovery. Native browser reload is
a separate acceptance check from the server's publish receipt.

### Tool discovery and autonomous development checks

The AI's `tool_help` reads the tools actually supplied for the current turn,
including their argument names. `topic: "web"` includes a built-in KilnWeb guide
covering HTML composition, router/controller APIs, forms and CSRF, live events,
layouts, CSS, worker arguments, branding and the development workflow. The guide
is versioned with Kiln; it cannot add tools or permissions. Read-only/background
turns do not gain source/build/publish capabilities through the guide.

The foreground development workflow now supports:

1. Discover the project and read its paginated current source.
2. Compile exact proposed edits using `validate_web_source`. This creates a
   `validated` or `failed` receipt, without deploying or saving the source.
3. Inspect bounded diagnostics and correct a failed proposal with different edits.
4. Publish the corrected edits once with `update_web_source`; publication still
   recompiles and checks the current source, SDK and authorization.
5. Report the controller receipt and its automatic HTTP root inspection.

`read_web_changes` inspects retained receipts. `inspect_web_preview` reads a bounded
unauthenticated GET from the registered app's origin. The command-line equivalent
is `web preview APP/MODULE /PATH`. It accepts a relative app path only, follows no
redirects, carries no cookies/credentials/proxy, has request/resource deadlines
and reads at most 64 KiB before returning a 2,500-character body excerpt. It cannot
fetch arbitrary hosts or claim browser/interactivity acceptance. Page bodies and
source are untrusted reference data, not instructions or grants.

Post-publish HTTP inspection failure does not invalidate a committed release or
trigger another publish. A failed/unconfirmed publication still ends the turn;
compile-only correction is deliberately separate from retrying a live operation.
All validation jobs count toward retained development artifact limits.

### Source history, diffs and rollback inside Kiln

Services → Changes / diffs opens retained changes with timestamps, publication
state, current-release marker and Git commit IDs. Select a change to view its
before/after diff. Press C for syntax-highlighted retained App.swift with line numbers,
D to return to the colored diff, Left/Right to browse versions in either view,
and PgUp/PgDn to scroll. F opens that revision's read-only file tree and code browser; W opens the current workspace. Esc returns to the selected history entry; R opens
confirmation before restoring its source. Releases opens a full-height result view;
Rollback reports its result in the same visible viewer. Keyboard and mouse use
the same management commands. `web history APP/MODULE` returns structured history,
`web diff APP/MODULE CHANGE-ID` (or `latest`) shows the diff,
`web code APP/MODULE CHANGE-ID` shows the complete integrity-checked source, and
`web restore APP/MODULE CHANGE-ID` builds and deploys a retained published source
as a new release. Existing history remains available.

Kiln maintains a private bare Git object repository per registered app, recording
published source snapshots and linking commit metadata to change/release IDs.
Existing retained receipts are imported when history is inspected; source hashes
are checked before committing or diffing. Git uses fixed plumbing operations,
private input/output files and a clean environment, with hooks, global/system
configuration, external diffs and text conversion disabled. No Git remote,
credentials, network listener, push protocol or package scripts are used. This
is local source history inside Kiln; remote Git hosting remains future work.

For registered development apps, `app rollback` coordinates the previous healthy
executable with its matching source snapshot. It verifies release generation and
source evidence, refuses to overwrite independently modified source, journals
its attempt, health-checks activation and then atomically saves the restored
source. Failed/uncertain activation never silently rewrites source or retries.
Legacy receipts need a matching previous published source before source-aware
rollback is possible. Ordinary installed app rollback retains its existing
release behavior. Approved AI rollback routes through the same development
coordinator, retaining one-shot operation receipts and authorization.

The AI has `read_web_history` and `read_web_diff` tools in its foreground
administrator development scope. It can inspect source/release history and
propose a source-aware rollback using its existing operation approval flow.
Retained job limits still apply; active and rollback executable artifacts must
not be deleted blindly. Rollback restores code/source, not application data or
in-memory state.

AI chat folds provider thinking by default while retaining the complete bounded
transcript. Ctrl-T or `/thinking` expands/collapses it, including during streaming
with Ctrl-T. Final publish results are concise, and detailed source diffs/history
live in the service views. Ctrl-S still freezes the screen for native copying.

The change browser opens the selected diff directly with Enter. Left/Right moves
between newer/older retained changes within the same viewer. Esc returns to the
history list with the selection preserved. R opens restore confirmation from the
diff; Cancel returns to that diff. Completing restore refreshes history before
returning. Added source lines are green and removed lines red across every wrapped
continuation; file headers and hunk markers use a separate metadata color.


### Project tree, editor and AI file operations

Services → Codebase / files opens the current workspace. The left pane shows
folders and files; Up/Down selects a file and Enter opens it. Tab moves focus to
the code pane, where arrows pan and scroll. The mouse wheel over code scrolls
that pane directly, without Tab; the tree scrolls independently. PgUp/PgDn and
the clickable page/top/end controls scroll within the file. The status line shows
visible line numbers and the horizontal column. Home/End jump to the start/end
of a file; Shift-wheel or horizontal wheel events pan long lines. Highlighting
covers keywords, types, strings, numbers and multiline comments/strings while
preserving source text and terminal geometry. Diff additions/deletions retain
their green/red semantic colors.

E edits the displayed file, A creates a relative file path and X requests deletion.
The editor accepts multiline paste, arrows, Home/End and newlines. Ctrl-D opens
publish confirmation; Cancel is selected initially. Esc offers to discard drafts.
Every publish compiles and health-checks before saving; stale replacements and
deletes fail if the file hash changed. App.swift cannot be deleted. Viewing
retained revisions is read-only; restoring remains a separate confirmed action.

A project holds at most 32 UTF-8 files, 64 KiB per file and 256 KiB total, within
8 path components. Swift, HTML, CSS, JS, JSON, Markdown, text and SVG files are
supported; binary/hidden files, symbolic links, absolute paths and traversal are
excluded. All Swift files compile together against the pinned SDK. Other text
files are source/history artifacts; serving assets requires explicit application
routes. The build has no package/dependency execution. On macOS the entire source
directory is replaced with one atomic exchange after source-drift checks, so
added/deleted files move with restores and rollbacks. Old single-file receipts
remain readable and restorable.

Commands: `web tree APP/MODULE [CHANGE]`, `web file APP/MODULE PATH [CHANGE]`,
`web browse APP/MODULE PATH [CHANGE]` and `web apply APP/MODULE OPERATIONS-JSON`.
The optional change ID addresses an integrity-checked retained tree; omitting it
reads the registered workspace. The AI has `list_web_files` and paginated
`read_web_file(module,path,offset)` behind the same foreground admin grant.
`validate_web_source` and `update_web_source` accept a JSON-string array:

```json
[
  {"path":"Views/Header.swift","action":"create","content":"import KilnWeb\nfunc heading() -> HTML { \"<h1>Hello</h1>\" }"},
  {"path":"App.swift","before":"unique old text","after":"new text"}
]
```

Create refuses an existing path. Delete is
`{"path":"Views/Header.swift","action":"delete","sha256":"HASH_FROM_READ"}`.
Full replace uses `action: replace`, the matching `sha256` and `content`.
Legacy `{before,after}` edits still target App.swift. Validate/update tools accept up to 256 KiB of JSON arguments in both ordinary
chat and refactor turns. Other tools retain a 4 KiB input guard. These are local
resource guards, separate from provider generation limits. When validate tools are available, only an unchanged proposal that passed validation
in the same turn can publish; a different proposal is rejected before any write and
can be validated safely. One publish attempt per turn remains in force. Tools cannot
expand the root grant, read host filesystem files or change SDK configuration.


### Refactor from the code browser

The visible **R Refactor** button (also keyboard R) offers:

- **Split into smaller components**: extract cohesive types into focused files.
- **One function per file**: separate ordinary methods into Swift extensions of
  the same type, such as `Models/CounterModel+snapshot.swift`. This preserves the
  type and its existing inheritance; inheritance is not used just to split files.

Cancel is selected initially. The action uses the selected provider and the
existing development autoPublish grant. It binds the displayed file hash and
registration, narrows the AI turn to project tools, reads the affected source,
validates the proposed group and publishes once after compilation and health
checks. Refactors use full-file replace operations bound to the file hashes returned by
inspection, plus create operations for extracted components. On refactor failure
(including failure receipt text from a completed command) the tree and code stay visible at the same position, with
a failure notice. V opens the complete diagnostic result; Enter/Esc returns to
code. No success is claimed and uncertain writes are not retried. Historical code is read-only;
W opens the current workspace before refactoring.

An explicit refactor turn can propose up to 32 operations with 256 KiB of tool
arguments, still bounded by the 32-file/256-KiB project snapshot. Ordinary AI edits
retain their 8-operation limit with the same 256 KiB validate/update argument guard. The source/registration guards run again
inside the build coordinator, before it snapshots files. All extracted functions
must compile together, and the complete refactor remains one retained change
with a diff and whole-project rollback. Initializers, stored properties, overrides
or other declarations stay in place when Swift cannot safely move them. Necessary
private/fileprivate access changes stay internal to the application, never public.
A large refactor that cannot fit must report any remaining scope.

Command: `web refactor APP/MODULE PATH SHA256 components|functions`. This is a
foreground administrator action requiring a registered project root and a current
Swift file. It grants neither host filesystem access nor unrelated service tools.


### Editor recovery after a failed build

When a manual editor publish fails, its result view retains the exact draft,
original file hash and new-file intent. Enter, D or Esc returns to editing locally;
recovery never refreshes source, rebases an edit or repeats the publication. A new
publish still needs explicit confirmation and the original hash must still match.
This also keeps drafts for uncertain outcomes: inspect the receipt/release before
requesting another write. Successful publishes and non-editor failures use the
ordinary result flow. Discarding an edited draft remains an explicit confirmation.

Compiler diagnostics wrap to the terminal width and support wheel, page, Home/End
scrolling. Result-line positions replace the code-pane controls in this view.
Draft recovery is connection-local editor state, rather than a saved draft on disk.
The OpenSSH acceptance script `editor-draft-acceptance.py` exercises failed compile,
recovery, default Cancel and an explicitly corrected healthy publish in a disposable
project without provider access or user credentials.

### Code and AI workspace

Services → Codebase / files opens the registered file tree, syntax-highlighted
source and AI chat together. `/code` in chat opens the selected service. At 110
columns or wider both panes remain visible; smaller terminals show the focused
pane. Drag the green center divider to change code/chat widths; the chosen
proportion adapts to terminal resizing and stays for this connection. Code keeps
at least 50 columns and chat 40. Ctrl-W switches between code and chat. Click either pane to focus it;
Tab switches the file tree and source within the code pane. Wheel and page keys
scroll the focused pane independently. Ctrl-S freezes painting and releases mouse
capture for native terminal selection/copy; Ctrl-S resumes.

Each ordinary chat message carries the displayed application, file, source hash,
revision, first visible line and unsaved-buffer flag. The chat header shows its
app/file context. Context is captured when sending; browsing another file while
inference runs does not retarget that turn. Registered file reads run separately
from inference, so navigating and scrolling remain available while it responds.
After a turn, clean code views refresh without moving the scroll position.
Unsaved local buffers remain in the connection and are not sent to the provider;
AI publishing is rejected while that turn's context contains unsaved edits, a
retained revision or a stale displayed hash. Save/discard and reload before asking
for another edit. AI changes remain limited to the active registered application,
with the existing build validation, auto-publish grant and retained history.
This workspace does not upload arbitrary filesystem content or provide code-range
selection to the model. Manual editor publishes still require confirmation.

Erebine requests omit both `max_tokens` and `max_completion_tokens`, allowing the
actual served model and its remaining context window to determine generation
capacity. Kiln does not impose a fixed generation budget or override reasoning
effort. This follows the [Erebine API contract](https://erebine.ai/docs/api-reference#max_tokens-and-the-context-window),
including routed endpoints where the served model can differ from the model name
in the request. No token-clamp augmentation is needed without a client ceiling.

Separate local resource guards remain: response messages are bounded to 256 KiB,
transport buffering/timeouts are bounded, conversation history has its existing
limits, and tool arguments are validated. Those protect Kiln's memory, connection
lifecycle and write integrity; they are not advertised as Erebine model limits.
Incomplete tool calls never execute, and a failed turn is never automatically
replayed. Reasoning remains visible/retained under the existing transcript limits.

### Swift IDE workspace

Registered Swift applications use the installed SourceKit-LSP beside their pinned
SDK compiler. Kiln creates a private snapshot and compilation database from the
registered compiler flags and all project Swift files, including open drafts.
It never runs Package.swift, package plugins, a user shell or dependency downloads.
The language process uses the existing file/network sandbox, with the installed
SourceKit XPC service name read from that toolchain's metadata and explicitly
allowed for semantic requests. Language processes and snapshots are bounded and
cleaned up; permissions are checked again before returning results.

The code toolbar provides **Build**, **Run**, **Def**, **Wrap** and **Complete**:

- **Complete / Ctrl-Space:** compiler-backed Swift suggestions at the caret. Typing
  a dot also requests member completion. Arrows select, Enter inserts the returned
  edit, Esc closes. Typing while a request runs preserves input and discards a
  reply that belongs to an older buffer.
- **Def / F12:** click a symbol in source, request its definition, and click or
  press Enter on the returned project location. Unsaved buffers survive navigation
  and reappear when returning through the tree. SDK definitions outside the
  registered project are reported without opening arbitrary filesystem paths.
- **Build / F11:** compile a private snapshot of the current application and open
  buffers. Compiler errors/warnings show file, line and column; click or Enter
  opens that location. Failed builds preserve buffers and the running application.
- **Run / F5:** restart the selected application's deployed release through Kiln's
  existing supervisor and readiness check. Publish pending drafts with Ctrl-D
  first; Run never silently discards or deploys unsaved text. Manual publication
  commits pending file buffers together through the existing validated history
  path, with explicit confirmation.
- **Wrap / F6:** toggle visual source wrapping. The default is **Wrap OFF**, with
  horizontal scrolling through Left/Right in browse mode, Shift-wheel/horizontal
  wheel, or the `[<]`/`[>]` controls. In edit mode Left/Right move the caret and
  horizontal scrolling follows it. Wrapping changes the view, never source text.

Use the toolbar if macOS reserves a function key or Ctrl-Space. Ctrl-W still
switches code/chat; dragging the center divider resizes both panes. This milestone
covers registered Kiln Swift applications, not arbitrary SwiftPM/Xcode workspaces.
Debugging, rename/find-references and general package/project import are future
work; the current language service does not pretend those capabilities exist.

### Modal editor and horizontal navigation

F7 or the toolbar's **Vim** button toggles an optional normal/insert editing mode
for this connection. Normal mode supports `hjkl`, `w/b`, `0/$`, `gg/G`, `i/a/I/A`,
`o/O`, `x/dd`, undo `u`, and redo Ctrl-R. Escape returns to normal mode without
throwing away the draft. Tab moves between the file tree and source; pending
buffers survive file navigation. `:w` opens the existing compile/publish confirmation
with Cancel selected. `:q` closes only when there are no pending changes.
`:set wrap`, `:set nowrap`, and `:set novim` are also supported. This is a basic
Vim editing mode, not an embedded Vim installation with plugins or every command.

The source pane displays a highlighted caret line, a block cursor and an explicit
line/column position. ViewCol identifies the horizontal viewport rather than the
caret. `<` in the number gutter means content is hidden on the left; `>` replaces
the right border on lines that continue beyond the viewport. Shorter rows are
padded on every repaint. Horizontal SGR wheel events from a trackpad pan the code,
as does Shift-wheel. Shift-Left/Right and the footer's arrow buttons provide
fallbacks when the terminal does not forward sideways gestures. No-wrap remains
the default; Wrap/F6 is available independently of Vim mode.
