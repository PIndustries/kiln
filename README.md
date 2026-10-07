# Kiln

A modular Swift application environment by P.Industries. Private development prototype.

Kiln's runtime runs independently of its interfaces. SSH is an optional module. Applications are logical groups of independently deployed modules: installing a WebSocket module does not require restarting an existing REST module.

## What works

- Public-key-only SSH shell and noninteractive commands (default: `127.0.0.1:2222`).
- Persistent Ed25519 host identity; only the configured administrator is accepted.
- Optional local stdin console, including with SSH disabled.
- Installation of a trusted, locally compiled executable from a JSON manifest.
- Versioned local release directories, separate processes, start/stop/restart, health checks and log tail.
- Installed-module persistence and restoration of desired running modules after clean shutdown.
- Independent REST and WebSocket example services.

This is **not a production sandbox or cluster**. Modules run as the same OS user as Kiln. There is no automatic crash restart, resource enforcement, ingress gateway, remote adoption, Git build pipeline, update/rollback operation, secrets service, installer or appliance yet. No arbitrary code is loaded into the supervisor's address space. A crash is contained at the OS process boundary; workers within one module share its fate. Abrupt supervisor death and child-process reconciliation are not yet handled; use clean shutdown.

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
ssh -p 2222 admin@127.0.0.1
```

Verify the first connection's fingerprint against:

```sh
ssh-keygen -lf .kiln/ssh-host-ed25519.pub
```

Within the shell:

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

The shell does not execute host shell commands. Admins can, however, install arbitrary trusted local executables, so SSH access is privileged administrative access. Paths with spaces and full terminal line editing are not implemented. `exit` disconnects the session; Ctrl-C in the runtime's host terminal shuts down Kiln and its modules.

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
  +-- KilnCommands --> KilnRuntime
  +-- KilnSSH -------> KilnCommands
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
