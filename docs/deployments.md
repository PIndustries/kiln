# Health-checked releases and rollback

Kiln can deploy a trusted local executable, admit it through a health check, switch a stable loopback ingress port, and roll back to the previous release. REST, static pages, server-rendered pages and WebSockets can use the same TCP forwarding path. The bundled example serves REST and WebSocket echo; it is not a full website framework.

This path is implemented on one macOS host. Remote installation, public HTTPS certificates, Git builds, artifact downloads/signatures and cluster placement are not implemented by this command. A saved bastion server is not automatically a Kiln worker.

## Try a complete release cycle

From the repository after `swift build -c release`:

```sh
python3 scripts/deployment-manifests.py \
  --executable "$PWD/.build/release/kiln-example-backend" \
  --output "$PWD/releases-demo"
.build/release/kiln up --state "$PWD/.kiln" \
  --authorized-keys "$HOME/.ssh/id_ed25519.pub"
```

For a binary distribution, use its `kiln` and `kiln-example-backend` files instead of `.build/release/`. No installer or root access is required; run the binary from its extracted directory. Keep the state directory across upgrades. Verify the distribution's checksums before using it; these checksums detect accidental changes and are not a publisher signature.

SSH into Kiln, open the command drawer with backtick, and run (substitute the printed absolute manifest path):

```text
app deploy /absolute/path/releases-demo/26.10.07.1.json
app health release-demo/backend
app releases release-demo/backend
```

Locally, visit `http://127.0.0.1:18090/api/hello` or `/api/version`. WebSocket echo is `/ws` on that same port. In the **Services** row menu, **Releases** shows the active version, previous version and ingress address; **Rollback** requires confirmation.

Update without restarting Kiln:

```text
app deploy /absolute/path/releases-demo/26.10.07.2.json
app releases release-demo/backend
app rollback release-demo/backend
```

The ingress address stays `127.0.0.1:18090`. `/api/version` reports the serving worker's version. An unsuccessful deployment leaves the active release unchanged. Successfully stored versions are immutable: rebuild under a new version, or use rollback for the immediately previous version.

## Access through SSH

For a remote Kiln whose SSH listener is already reachable, verify its host fingerprint through a trusted channel and create an authenticated tunnel:

```sh
ssh -N -o ExitOnForwardFailure=yes -p 2222 \
  -L 127.0.0.1:18090:127.0.0.1:18090 admin@YOUR_KILN_HOST
```

Then browse `http://127.0.0.1:18090` on your computer. The network hop to Kiln is encrypted by SSH; both HTTP endpoints are loopback. Authorized Kiln administrators can forward to active managed ingress ports. Arbitrary destinations still require the existing saved-server allowlist. This is administrative access, not a public HTTPS endpoint. Kiln binds SSH to loopback by default; deliberately configure `--host` and your host firewall when providing remote access.

## Release contract

```json
{
  "application": "release-demo",
  "name": "backend",
  "version": "26.10.07.1",
  "executable": "/absolute/path/kiln-example-backend",
  "arguments": ["--websocket"],
  "healthURL": "http://127.0.0.1:19090/health",
  "ingressPort": 18090
}
```

Kiln copies the executable into its release directory, starts a separate process, and supplies `KILN_PORT`, `KILN_RELEASE_VERSION`, `KILN_APP_NAME` and `KILN_DATA_DIR`. The app must listen on loopback at `KILN_PORT` and return HTTP 200 at its configured health URL only when it is ready. Legacy apps may use explicit port arguments instead. Three consecutive successful probes with the candidate process alive admit the release. The initial deployment also checks readiness before opening ingress.

Every candidate uses a different worker port from the active release. The ingress port remains fixed. The persisted active and previous manifests survive clean shutdown; desired-running apps are checked again during startup. Rollback starts and checks the previous executable before switching traffic.

```text
SSH admin -> app deploy manifest
                   |
              copy executable
                   |
              candidate process -- HTTP readiness
                   |
              persist active + previous
                   |
client -> stable loopback ingress -> new connections: candidate
                                 -> existing connections: old worker
                                                         |
                                                    drain and stop
```

`KilnIngress` is a separate Swift package target. It forwards TCP bytes with backpressure, preserving HTTP upgrades and keeping each connection on one worker. It does not perform host/path routing, TLS termination or cross-node routing.

## Operational boundaries

- Existing connections have up to **30 seconds** to finish after the switch; remaining connections are closed, then the old process stops. Long-lived WebSockets need client reconnect logic. HTTP keep-alive connections stay with the old generation until closed or drained.
- `app deploy` returns after draining. The active version may already be visible while the command waits. Concurrent lifecycle changes for the same app are rejected. Disconnecting the SSH client does not cancel an accepted deployment.
- Health admission is a point-in-time check. Runtime metrics stream in the dashboard; `app health` probes health on demand. Continuous health-based eviction, automatic crash restart and multi-instance failover are not provided.
- Releases share `KILN_DATA_DIR`. Database/schema changes must remain compatible while both versions run. Code rollback does **not** undo writes or migrations.
- Workers use Kiln's OS account. Only deploy trusted programs. Environment inheritance is restricted, but this is not a sandbox or resource quota system.
- Clean supervisor restart briefly stops application traffic. Abrupt supervisor death may orphan app processes; reconcile those before restarting. Remote terminal sessions have their separate service lifecycle.
- Packaging currently copies one executable. Bundle resources, architecture compatibility checks, signing and release garbage collection remain future work.

## Validation

```sh
swift test
KILN_BIN_DIR="$PWD/.build/release" python3 scripts/deployment-integration.py
```

The integration test uses real OpenSSH and compiled Swift workers. It exercises encrypted ingress, continuous HTTP requests during update/rollback, an unfinished HTTP request and an open WebSocket across cutover, rejected candidates, concurrent lifecycle rejection, and persisted rollback after clean restart.
