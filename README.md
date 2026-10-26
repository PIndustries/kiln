# Kiln

Kiln is a Swift server runtime from P.Industries. It runs application modules as separate processes and gives you an SSH interface to deploy them, inspect their health, and manage the host.

The runtime works without SSH. REST services, WebSocket services, and other trusted executables can be installed and updated independently. Updating one application module does not require restarting the supervisor or its neighbors.

[Documentation](https://github.com/PIndustries/kiln/wiki) · [Issues](https://github.com/PIndustries/kiln/issues) · [Roadmap](https://github.com/orgs/PIndustries/projects/15) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

## What it does

- **Application lifecycle:** versioned executable releases, health-checked deployment, stable loopback TCP ingress, connection draining, rollback, and optional bounded crash recovery.
- **SSH management:** a terminal dashboard, command drawer, mouse support, live host/process metrics, and noninteractive commands through standard SSH clients.
- **Access control:** named public-key users, administrator/operator/viewer roles, module scopes, live revocation, and bounded audit records.
- **Credentials:** an encrypted server-side Vault with explicit per-module grants. On macOS, the bastion integration also supports Keychain-backed SSH keys and pinned destinations.
- **Remote terminals:** named sessions, switching, and two-pane layouts. A separate session service keeps remote shells alive across viewer disconnects and dashboard restarts.
- **AI operations:** native Erebine, OpenAI, Claude, Grok, DeepSeek and local Ollama chat with streaming, task and approval controls, and a fixed set of Kiln tools. Application changes require explicit approval; background investigations are read-only.
- **Peer administration:** explicit mutual node adoption, pinned encrypted transport, typed remote operations, and durable operation receipts.

Kiln is under active development. It is not a hostile-code sandbox: applications run as the same OS user as the supervisor. Peer administration does not provide a consensus cluster, automatic placement, or failover. Read the [operating boundaries](docs/release-readiness.md#current-operating-boundaries) before putting it on a server.

## Download and run

Prebuilt macOS (Apple Silicon) and Linux (x86_64) archives are available under
[Releases](https://github.com/PIndustries/kiln/releases). No source checkout or
compiler is required. Verify the adjacent SHA-256 file, extract the archive, and
run from its directory:

```sh
./bin/kiln --version
./bin/kiln up --state "$HOME/.kiln" --authorized-keys "$HOME/.ssh/id_ed25519.pub"
```

From another terminal, check the host key and connect:

```sh
ssh-keygen -lf "$HOME/.kiln/ssh-host-ed25519.pub"
ssh -e none -i ~/.ssh/id_ed25519 -p 2222 admin@127.0.0.1
```

Starting with 26.10.11.2, Linux packages include the Swift runtime; Ubuntu 24.04
system libraries are still required. macOS packages are not yet Developer-ID signed
or notarized. See [package installation](docs/packages.md) for requirements,
checksums and safe upgrades. The source workflow below is for development.

## Build and connect

Release validation uses **Swift 6.2.3** on Apple Silicon macOS and Linux x86_64. The package targets macOS 14 or later; its tools-version declaration is not a promise of compatibility with older compilers. Bastion credential storage currently depends on macOS Keychain. See [Linux service setup](docs/linux-service.md) for Linux deployment.

```sh
git clone https://github.com/PIndustries/kiln.git
cd kiln
swift build
swift test
.build/debug/kiln up --state .kiln --authorized-keys ~/.ssh/id_ed25519.pub
```

Use an existing public key, or generate one with `ssh-keygen -t ed25519`. The authorized-key file accepts plain OpenSSH public keys, without `authorized_keys` options. On first initialization, it bootstraps the `admin` identity; later access changes go through Kiln's [identity policy](docs/identities.md).

From another terminal:

```sh
ssh-keygen -lf .kiln/ssh-host-ed25519.pub
ssh -e none -i ~/.ssh/id_ed25519 -p 2222 admin@127.0.0.1
```

Compare the host fingerprint before accepting it. The default listener is loopback-only. `-e none` lets Kiln receive the tilde key instead of OpenSSH treating it as a local escape.

The dashboard supports keyboard and mouse navigation. Select a service and press Enter to manage it. Backtick or `~` opens the command drawer; `help` lists commands. In AI Chat, Tab opens or focuses tasks and approvals, and Ctrl-S freezes redraws for text selection. The default theme is black and green. In the drawer, `theme` shows saved colors; `theme green|cyan|amber|mono|default` selects a preset, and `theme custom <accent> <background> <text> <muted>` accepts four distinct ANSI palette indices (0–255). In chat use `/theme` with the same arguments. Choices are saved on the node for your authenticated SSH identity and key, and restored on reconnect or runtime restart. Other connected sessions keep their current colors until reconnecting. `theme default` saves the black-and-green default. Non-PTY connections use plain text:

```sh
ssh -i ~/.ssh/id_ed25519 -p 2222 admin@127.0.0.1 'app list'
```

You can also run a local console without an SSH listener:

```sh
.build/debug/kiln up --state .kiln --no-ssh --console
```

## Run two independent modules

Generate manifests for the included examples:

```sh
python3 scripts/example-manifests.py --output /tmp/kiln-examples
```

Then run these commands in Kiln:

```text
app install /tmp/kiln-examples/rest.json
app start storefront/rest
app install /tmp/kiln-examples/websocket.json
app start storefront/websocket
app list
```

KilnWeb adds [server-rendered pages, controller routes and live views](docs/web-framework.md), with a separate `kiln-example-web` worker. Run it on port 18082 and open `/counter` in two tabs for real-time server-rendered updates.

The REST example serves `http://127.0.0.1:18080/api/hello`. The WebSocket example echoes text and binary messages at `ws://127.0.0.1:18081/ws`; fragmented frames are not supported. Both expose `/health` and use local, unencrypted connections.

The examples run the same executable with different arguments in separate processes. Your modules can use different executables and dependencies. Installation currently copies the executable only; packaging assets, app bundles, and shared libraries is not implemented.

## How it fits together

```text
SSH dashboard / local console
              |
        KilnCommands -------- KilnAI (fixed tools and approval gates)
              |
        KilnRuntime --------- KilnVault / telemetry
         |        |
    supervisor    stable ingress
         |        |
      independent application processes

Optional: adopted peer administration and persistent remote terminal service
```

Libraries are composed at build time. Application modules are deployed as executable processes, not loaded into the supervisor's address space. See [architecture](docs/architecture.md), [deployments](docs/deployments.md), and [supervision](docs/supervision.md) for lifecycle and recovery details.

## Documentation

- [Users, roles, and module scopes](docs/identities.md)
- [Vault setup and grants](docs/vault.md)
- [AI configuration, tools, and tasks](docs/ai.md)
- [Background-agent events and recovery](docs/agent-events.md)
- [Owned workspace recovery](docs/workspace-recovery.md) and [sovereignty roadmap](docs/sovereignty-roadmap.md)
- [Bastion destinations](docs/bastion.md) and [persistent terminals](docs/sessions.md)
- [Peer adoption](docs/clustering.md) and [Linux resource limits](docs/resources.md)
- [Release checks and operating boundaries](docs/release-readiness.md)
- [Ecosystem plans](docs/ecosystem.md)—planned capabilities, not shipped features

Public TLS/ACME ingress, Cloudflare and Resend integrations, source-build delivery, replicated storage, appliance images, and native Apple clients are not implemented.

## Development and releases

Start with `swift test` and `python3 scripts/integration.py`. Integration tests use disposable state and real SSH, HTTP, and WebSocket clients. See [CONTRIBUTING.md](CONTRIBUTING.md) for the other suites, platform requirements, and live-provider tests.

Release identifiers use `YY.MM.DD.BUILD`. The build number starts at 1 each day. Keep the packaged version, source commit, and test results together when distributing or upgrading a node.

## License

Copyright (c) 2026 P.Industries and Kiln contributors.

Kiln's original code and documentation are licensed under [Apache 2.0](LICENSE). Third-party dependencies and separately marked material retain their own licenses and attribution. Preserve applicable dependency notices when redistributing binaries; the inventory and full texts are in [THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt).

SSH connection problems: see [authentication troubleshooting](docs/ssh-troubleshooting.md).
