# Current preview acceptance

2026-10-23 local validation started from `main` revision
`3da0f2e09dc4a8201b99d4f95da8add727e1e4f7` (same tree as released
`v26.10.13.3`). The preview-acceptance branch adds provider token diagnostics,
complete provider-header labels, access/billing descriptions, ChatGPT usage-limit
recovery instructions, and deterministic AI acceptance through real SSH.

## Fresh local evidence

Host: Apple Silicon macOS, Apple Swift 6.4. The default Swift Build engine failed
while compiling SwiftTerm's Metal resource because the host lacks the Metal
Toolchain. The native SwiftPM build system succeeds without source/dependency
changes:

```sh
KILN_TEST_GROK_SANDBOX=1 swift test --build-system native --force-resolved-versions --jobs 4
```

The baseline passed 152 tests; PR #49 passed 166 and PR #50 adds a provider-visibility
regression covering dashboard, command drawer, chat and narrow task layouts. This is additional
compiler coverage, not a replacement for Swift 6.2.3/macOS/Linux release gates.

The following real local suites passed, using disposable runtime state:

- SSH/REST/WebSocket installation, independent process lifecycle, crash isolation,
  automatic restart, stopped intent, host identity restoration and SSH-disabled run.
- Five supervisor SIGKILL recovery cycles, interrupted candidate promotion/drain,
  rollback and final descendant cleanup.
- Deployment and rollback with live HTTP/WebSocket connections: 378 concurrent
  encrypted requests, zero failures in the recorded run.
- Named identities, role/module scope, live revocation and last-admin protection.
- Peer discovery/adoption, typed encrypted operations, revocation, sender death,
  durable receipts and no mutation replay.
- Durable AI recovery through separate SSH sessions, one approved restart,
  verified replacement health and no replay after cold restore.
- 1,024 ingress WebSockets, excess-connection rejection, SSH admission deadlines,
  oversized pre-auth input and identity-policy failure handling.
- SSH authentication diagnostics, including stalled agent signing and recovery.
- Terminal dashboard actions, metrics, mouse/keyboard, resize and cleanup.
- Vault hidden input, rotation, scoped credential delivery, revoked grants and
  encrypted reopen.
- Offline AI through the ordinary local Ollama HTTP route and OpenSSH/pyte:
  multiple answer frames, frozen selection during content arrival, cancellation,
  successful follow-up, tool results, mouse denial/keyboard approval with actual
  worker PID evidence, and foreground disconnect/reconnect without stale proposals.
- Backtick/tilde always selects the command drawer from AI chat or the dashboard.
  Real SSH verifies `status` is executed as a CLI command after leaving chat.
  Separate composer histories prevent chat prompts from appearing as CLI history.
- Authenticated Erebine OpenSSH/pyte chat: 118 activity frames, 24 partial-answer
  frames and 11 waiting frames; frozen selection and a task surviving disconnect.
  The workspace suite also passed mouse denial without a PID change, keyboard
  approval with a new worker PID, live task completion and narrow navigation.
- A deterministic Erebine transport fixture returned HTTP 429 with a five-second
  retry delay through the production retry/SSE code and real OpenSSH. A second
  SSH connection created a durable task; the foreground sidebar showed its
  completion while the retry countdown was still visible, then retained it after
  inference recovered. Run `scripts/ssh-retry-acceptance.py` with the terminal-test
  Python environment (`--build-system native` on this Swift 6.4 host).
- Live ChatGPT sign-out confirmed remote renewable-session revocation and local
  credential removal. `ai accounts` reported signed out and model discovery was
  rejected pending renewed consent. The account was subsequently reconnected
  with fresh consent, then restored and verified after restart.

The offline fixtures passed in both macOS and Linux server workflows. Exact
candidate evidence:

- PR #49: [server validation](https://github.com/PIndustries/kiln/actions/runs/40010621164),
  [package, clean install and compatible rollback](https://github.com/PIndustries/kiln/actions/runs/40010621484),
  and [secret scan](https://github.com/PIndustries/kiln/actions/runs/40010621304).
  The downloaded macOS archive passed its SHA-256, source-tree and 62 file-digest
  checks, then real local SSH/REST/WebSocket installation tests.
- PR #50: [server validation](https://github.com/PIndustries/kiln/actions/runs/40017763471)
  passed all four jobs, and the secret scan passed. Provider/model/access labels
  were verified through real SSH on the running local development preview.

Both PRs are merged. The local runtime state is stored outside the checkout;
ChatGPT was reconnected for the SSH admin identity after the revocation check,
with live model discovery, inference and account restore after restart verified.
Erebine remains the selected named profile. Credentials stay in the encrypted
Vault with its master key stored separately. The prior verified package is retained.

ChatGPT consent, model discovery, account restore, native tool/stream/cancellation,
renewal and sign-out passed. Fresh Erebine native acceptance also passed with an
operator-supplied scoped Vault credential.

## Installed core preview and remaining coverage

PR #51 promoted the merged core to `26.10.23.2`. Its
[server validation](https://github.com/PIndustries/kiln/actions/runs/40037688857),
[package/clean-install/upgrade/rollback checks](https://github.com/PIndustries/kiln/actions/runs/40037688944),
and [secret scan](https://github.com/PIndustries/kiln/actions/runs/40037688969)
passed. The downloaded macOS package passed archive, source-tree and all 62
embedded file-digest checks before local SSH/REST/WebSocket verification and
installation. ChatGPT cold restore, model discovery and inference passed; Erebine
remained selected.

The operator confirmed Apple Terminal selection, copying into another app and
Ctrl-S return to chat on 2026-10-23. Additional native terminal clients remain
tracked in issue #9. Live Grok and other unconfigured providers remain separately
unverified.

PR #53 adds the black-and-green brand default and saved terminal colors scoped
to each authenticated SSH identity/key. Its local development preview is distinct
from the retained validated `26.10.23.2` package. The change does not publish a
new binary release or migrate application state.

Portable application bundles are deferred at the maintainer's request. Current
work prioritizes features and stability in the macOS operator workflow.
