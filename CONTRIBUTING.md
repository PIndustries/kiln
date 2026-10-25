# Contributing to Kiln

Use [Issues](https://github.com/PIndustries/kiln/issues) for bugs and feature proposals. For a larger change, describe the problem and intended behavior before opening a pull request. Report security vulnerabilities through the [private reporting process](SECURITY.md), not a public issue.

Kiln is licensed under the Apache License, Version 2.0 (`Apache-2.0`); see [LICENSE](LICENSE). Keep runtime state, credentials, customer configuration and generated build artifacts outside Git.

By submitting a contribution for inclusion, you agree to license it under `Apache-2.0`. Submit only work you have the right to contribute, and preserve third-party copyright and license notices. No copyright assignment is required.

Use Swift 6.2.3, the compiler used by release validation. Preserve `Package.resolved` unless a dependency update is intentional. The platform consists of separate Swift package targets; keep domain authorization in the command/runtime boundaries rather than relying on a terminal view or AI prompt.

```sh
swift test --jobs 2
python3 scripts/integration.py
python3 scripts/web-framework-integration.py
python3 scripts/transport-integration.py
python3 scripts/crash-recovery-integration.py
python3 scripts/identity-integration.py
python3 scripts/cluster-integration.py
python3 scripts/deployment-integration.py
```

For deterministic AI streaming and approvals through real SSH, install the pinned
terminal requirements in a disposable virtual environment and run
`python scripts/offline-ai-terminal-integration.py` from that environment. It
starts a loopback Ollama-protocol fixture; no model or provider account is used.

These scripts use isolated state, disposable workers and local SSH clients. The transport test raises its own soft descriptor limit to 4,096 to exercise 1,024 real WebSockets. The multicast variant (`KILN_TEST_MULTICAST=1`) advertises on the LAN and must run only in an isolated test network. `scripts/resource-integration.py` requires a disposable Linux systemd/cgroup v2 host with privileged test setup; do not run it casually on a production node.

For an optimized build, run `swift test -c release --jobs 2` and set `KILN_BIN_DIR="$PWD/.build/release"` when invoking integration scripts. Never overwrite the executable of a running node. Package a new version separately, verify it, then perform an intentional upgrade.

AI live tests require an explicitly supplied configured Vault and call a paid provider. Do not put credentials in command arguments, fixtures or test reports. Keep deterministic authorization/transport tests separate from live-provider evidence.

A change should include a concrete failure scenario and relevant validation. Test persistence failures, cancellation, overload and recovery when they affect the change. Do not replace real interoperability checks with a mocked production path. Never claim a partial or timed-out mutation was undone without reconciling its receipt and actual state.

Use `YY.MM.DD.BUILD` release identifiers. See [release readiness](docs/release-readiness.md) for acceptance gates, honest operating limits and distribution checks.

## Pull requests

Keep changes focused. Explain the failure or use case, what the patch changes, and which checks you ran. Include platform and compiler details when they matter. If a check needs hardware, credentials, or a provider account you do not have, say so; do not imply it passed.

Preserve existing author attribution and license notices. Do not add credentials, runtime state, private endpoints, customer data, or generated binaries. Scrub logs and screenshots before attaching them.

The [Wiki](https://github.com/PIndustries/kiln/wiki) provides the documentation entry point. Detailed implementation and operating notes live in `docs/` and should change with the code.

## Continuous validation

[Server validation](.github/workflows/server.yml) runs the same checked-out revision for each push and pull request. A green macOS job alone does not establish Linux compatibility, or vice versa. Check all three jobs before accepting a release commit:

| Job | Environment | Coverage and boundary |
| --- | --- | --- |
| macOS arm64 / Swift 6.2.3 | GitHub-hosted `macos-15`, official signed Swift 6.2.3 installer | Locked-dependency unit/policy tests; real OpenSSH, HTTP, WebSocket, supervisor SIGKILL, admission limits, identities, loopback peers, deployment and rollback. Records the exact checkout revision and compiler in the job summary. macOS rejects requested Linux hard resource limits. |
| linux | `swift:6.2.3` container on an Ubuntu runner | Locked-dependency unit/policy tests and the corresponding server integration suites, including isolated multicast discovery. This container job does **not** prove systemd delegation or kernel resource enforcement. |
| linux-resources | Native Ubuntu 24.04 hosted runner with systemd/cgroup v2; binaries built in `swift:6.2.3` | Privileged fixture setup creates an unprivileged delegated Kiln service. Verifies actual CPU/PID/memory enforcement, descendant cleanup, diagnostic-storage obstruction and service crash recovery. This is a disposable hosted Linux VM test, not a container-only simulation or whole-OS reboot test. |

These jobs require no repository secrets and do not run `ai-live-integration.py`, `ai-terminal-integration.py` or `ai-workspace-integration.py`. Live Erebine checks remain explicit, separately authorized runs against a configured disposable Vault; do not add paid-provider credentials to pull-request jobs. Keychain-backed bastion and terminal UI suites remain separate platform-specific checks, not implied by this server workflow.
