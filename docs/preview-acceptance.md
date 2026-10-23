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

The baseline passed 152 tests; the final preview-acceptance changes passed 165. This is additional
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

The offline fixture is included in both macOS and Linux server workflows. A
workflow change is not evidence that those hosted jobs have passed.

## Remaining release gates

- Live ChatGPT sign-out/revocation remains untested; the user-requested account
  connection was retained. Consent, model discovery, account restore, native
  tool/stream/cancellation and renewal passed. Fresh Erebine native acceptance
  also passed with an operator-supplied scoped Vault credential.
- Native terminal clipboard/client-matrix acceptance and real SSH sidebar behavior
  during an Erebine retry. The attempted native Terminal clipboard check could
  not run: Orca lacks Accessibility permission and the alternate computer-use
  provider blocks Terminal. No clipboard pass is claimed.
- Fresh Swift 6.2.3 Linux/macOS CI, Linux kernel resource enforcement and packaged
  clean-install/upgrade/rollback checks for the final candidate.
- Live Grok account and other API providers remain separately unverified where
  account credentials/consent are unavailable.

No existing user node was upgraded and no replacement release was published by
these local checks. Portable application bundles remain the next platform
milestone after the core preview acceptance work.
