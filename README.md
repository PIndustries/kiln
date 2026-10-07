# Kiln

A modular Swift application environment by P.Industries. Private development prototype.

Kiln's runtime runs independently of its interfaces. SSH is an optional module. Applications are logical groups of independently deployed modules: installing a WebSocket module does not require restarting an existing REST module.

## What works

- Full-screen SSH dashboard with colors, aligned service rows, clickable tabs/actions, mouse-wheel navigation and a command drawer.
- Shared host telemetry sampler and bounded one-second observation streams, with host CPU/memory/disk/load/uptime and supervisor/service CPU/RSS.
- Public-key-only SSH authentication and noninteractive commands (default: `127.0.0.1:2222`).
- Saved bastion destinations, allowlisted OpenSSH ProxyJump, and macOS Keychain-backed Ed25519 keys for pinned remote command execution.
- Persistent Ed25519 host identity; only the configured administrator is accepted.
- Optional local stdin console, including with SSH disabled.
- Installation of a trusted, locally compiled executable from a JSON manifest.
- Versioned local release directories, separate processes, start/stop/restart, health checks and log tail.
- Installed-module persistence and restoration of desired running modules after clean shutdown.
- Independent REST and WebSocket example services.

This is **not a production sandbox or cluster**. Modules run as the same OS user as Kiln. There is no automatic crash restart, resource enforcement, ingress gateway, remote adoption, Git build pipeline, update/rollback operation, general-purpose secrets service, installer or appliance yet. No arbitrary code is loaded into the supervisor's address space. A crash is contained at the OS process boundary; workers within one module share its fate. Abrupt supervisor death and child-process reconciliation are not yet handled; use clean shutdown.

## Build

Requires Swift 6.1 or newer. Verified locally on Apple Silicon macOS with Swift 6.2.3. Linux is an intended target, not yet verified.

```sh
swift build
swift test
python3 scripts/integration.py
```

## Run

Use an authorized public key file (plain OpenSSH keys; authorized_keys options are not supported):

```sh
.build/debug/kiln up --state .kiln --authorized-keys ~/.ssh/id_ed25519.pub
```

From another terminal:

```sh
ssh -e none -p 2222 admin@127.0.0.1
```

Verify the first connection's fingerprint against:

```sh
ssh-keygen -lf .kiln/ssh-host-ed25519.pub
```

Interactive SSH opens the dashboard by default:

- Up/Down or j/k selects a service; Enter opens start/stop/restart/health/log actions.
- Stop and restart require confirmation. Escape cancels.
- Backtick or `~` opens/closes the command drawer. The `-e none` client option above prevents OpenSSH from intercepting tilde as a local escape prefix; backtick works with the default SSH configuration too.
- Tab completes commands and service IDs; Up/Down recalls session history.
- Left/Right, Home/End, Ctrl-A/E/U/K and Backspace/Delete edit a command.
- Page Up/Down scrolls output. Ctrl-C clears input; it does not cancel an operation already executing.
- Tab or 1/2/3/4 switches views (Overview, Services, Metrics, Help). q disconnects from the dashboard.
- The layout follows SSH-reported dimensions, including live window changes. The divider spans the viewport, the drawer uses half the height, and service columns size from their content and available width. Unknown dimensions retain the last known size; only an excessive total cell count is rejected to bound untrusted rendering work. Screens below 50x16 show a resize prompt.

The dashboard receives observation frames about once per second. Click tabs, service rows, action choices or the drawer divider; the wheel navigates services or scrolls command output. Standard xterm SGR mouse reporting is required. Mouse modes are disabled on normal exit; use your terminal's mouse-selection override (often Option or Shift) to select text while reporting is active. Running is not a health claim; use Check health to query an endpoint. New service IDs appear in the dashboard and completion automatically.

Commands in the drawer:

```text
help
status
app list
app install /absolute/path/rest.json
app start storefront/rest
app health storefront/rest
app logs storefront/rest
app stop storefront/rest
exit
```

Non-PTY sessions and TERM=dumb use a plain shell. `ssh ... "app list"` returns aligned plain text without color or full-screen controls.

The shell does not execute host shell commands. Admins can, however, install arbitrary trusted local executables, so SSH access is privileged administrative access. Paths with spaces can be quoted. The full-screen renderer uses printable ASCII cells; non-ASCII output is displayed as question marks, and terminal control sequences from logs are neutralized. `exit` disconnects the session; Ctrl-C in the runtime's host terminal shuts down Kiln and its modules.

Run without SSH:

```sh
.build/debug/kiln up --state .kiln --no-ssh --console
```

This never reads SSH keys or opens an SSH listener. The runtime target has no dependency on `KilnSSH`; the distributed executable currently links it as an optional feature.

## Load independent modules

```sh
python3 scripts/example-manifests.py --output /tmp/kiln-examples
```

In Kiln:

```text
app install /tmp/kiln-examples/rest.json
app start storefront/rest
app install /tmp/kiln-examples/websocket.json
app start storefront/websocket
app list
```

REST: `http://127.0.0.1:18080/api/hello`.
WebSocket: `ws://127.0.0.1:18081/ws` (text/binary echo; fragmented frames unsupported).
Both expose `/health`. Both are local-only and unencrypted example endpoints.

The sample uses the same compiled example executable with separate mode arguments, installed and started as two independent processes. Real projects can supply different executables with different Swift package dependencies. Local install currently copies only the executable: app bundles, assets and shared-library packaging are future work.

## Module boundaries

```text
kiln executable (composition root)
  +-- KilnRuntime ----> KilnKit (release contract)
  +-- KilnCommands --> KilnRuntime + KilnBastion
  |     +-- KilnBastion (server registry, Keychain, native SSH client)
  +-- KilnSSH -------> KilnCommands
  |     +-- KilnTerminal (UI state, input decoder, ANSI renderer)
  +-- local console -> KilnCommands

example executable
  +-- KilnHTTP
  +-- KilnWebSocket
```

See [the loading architecture](docs/architecture.md) for the distinction between build-time libraries and runtime modules, and the planned ingress model.

See [the ecosystem direction](docs/ecosystem.md) for source/prebuilt distribution, shared data, ingress, SSH interoperability and appliance requirements.

## Validation

`scripts/integration.py` uses real OpenSSH, HTTP requests and WebSocket frames. It checks rejected keys, interactive PTY sessions, command exit codes, independent module addition, process crash isolation, manual recovery, stable host keys, restart persistence, and operation without SSH. It creates temporary credentials and state and removes them afterward.

No open-source license has been selected yet.

### Terminal regression tests

`swift test` covers fragmented key sequences, paste safety, menu confirmations, editing, quoted arguments and layout bounds. The real PTY test also exercises SSH window changes and alternate-screen cleanup:

```sh
python3 -m venv /tmp/kiln-terminal-tests
/tmp/kiln-terminal-tests/bin/pip install pyte
/tmp/kiln-terminal-tests/bin/python scripts/terminal-integration.py
```

For optional image previews on macOS, install Pillow in the test environment and pass `--preview /tmp/kiln-previews`. These are development-only dependencies; the shipped terminal is native Swift.

## Basic observability

`KilnTelemetry` is independent of SSH and the terminal. `KilnCommands.observations()` exposes an `AsyncStream` with a newest-one-frame buffer; disconnected viewers cancel their subscriptions. Sampling is cached across viewers for approximately one second. The SSH renderer skips frames while its channel is not writable rather than accumulating screen updates. No external monitoring server is required.

Open the Metrics tab or run `metrics` in the command drawer/noninteractive SSH. Overview shows a compact host summary. Metrics includes a per-session ring of up to 60 CPU samples and the supervisor plus installed service processes. Missing values are displayed as unavailable; initial host CPU needs a second sample.

Metric definitions:

- Host CPU is busy time over the interval between OS CPU tick samples, normalized across all cores (0–100%).
- On macOS, resident memory means active + wired + compressor physical pages, not Activity Monitor's exact "Memory Used" definition and not memory pressure. Linux uses MemTotal minus MemAvailable.
- Disk free/total comes from the filesystem containing Kiln's state directory; APFS purgeable space is not added.
- Uptime is host uptime; load is the OS 1/5/15-minute load average.
- Process CPU is the OS `ps` percentage (its averaging differs from host CPU and may exceed 100%); RSS is resident memory. Samples do not include process command lines or environments.

The implementation is verified on macOS. Linux collection code remains unverified. This is local, ephemeral observability: no retained time-series database, alerting, distributed tracing, network counters, HTTP latency/error instrumentation or Prometheus endpoint yet. Existing service log commands return a bounded tail rather than a continuous log stream. Running process state is not an application-health guarantee.

## Bastion and managed SSH

See [bastion setup](docs/bastion.md) for saved destinations, ProxyJump and Keychain-managed credentials. Run `python3 scripts/bastion-integration.py` on macOS to test real forwarding, authentication, persistence and changed-host-key rejection. This test creates and deletes a temporary Keychain item.
