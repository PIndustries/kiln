# Worker recovery and operation receipts

A release manifest may set `"restartPolicy": "always"`. Omitted or `"never"` policies preserve manual restart behavior for existing applications.

Kiln checks desired workers every 250 ms. After an exit, an opted-in worker gets up to three automatic restart attempts, delayed by 1, 2, and 4 seconds. Failed launches and failed readiness checks count against the same budget. Managed ingress is disabled while a dead worker recovers and resumes only after normal readiness checks pass. Other modules continue running.

The dashboard and AI module inventory report `recovering`, then `failed` if the budget is exhausted. Sixty seconds of continuous process uptime resets the budget; this is not an application health guarantee. An explicit `app start app/module` resets the budget. An explicit stop persists the stopped intent and prevents recovery. Failed restoration of one application no longer prevents restoration of other applications or startup of the management plane.

Restart counters are currently in memory and reset on runtime restart. Worker recovery only applies while the supervisor is alive. It does not reconcile orphaned processes after SIGKILL, enforce resource limits, or implement cluster failover.

Approved AI start/stop/restart/rollback operations record a receipt in `state/operations` before execution. If that initial write fails, the operation is not executed. Completion records success or failure without saving prompts, credentials, or raw error output. `ai operations` lists the latest 50 receipts, available even without provider configuration.

A receipt remaining in `started` is displayed as **unconfirmed**. It may describe an in-flight operation or an interruption between a side effect and the outcome write. Inspect current module state before retrying. Receipts are not a transaction log or an exactly-once job queue. Pending approvals remain session-bound, single-use, expiring, and in memory. Files are private to the runtime user, not tamper-proof against that user. These records are atomic file replacements, not a guarantee against physical storage failure.

## Validation

CI uses Swift 6.2.3 on Linux and exercises unit/policy tests plus real OpenSSH, HTTP, WebSocket, crash recovery and restore. macOS release builds should start with `swift package clean` to avoid mixing cached clients with changes to Swift actor layouts. Run `swift build -c release`, then `KILN_BIN_DIR="$PWD/.build/release" python3 scripts/integration.py` before packaging.

Release 26.10.08.1 passed all 22 unit/policy tests on macOS and Linux x86_64, real SSH/REST/WebSocket recovery and restoration on both, managed deployment/rollback under 414 concurrent encrypted requests on macOS, and live Erebine proposal/approval/replay checks on macOS. Shutdown signal handling is installed before services become reachable, fixing a startup/stop race discovered by the Linux integration test.
