# Worker recovery and operation receipts

A release manifest may set `"restartPolicy": "always"`. Omitted or `"never"` policies preserve manual restart behavior for existing applications.

Kiln checks desired workers every 250 ms. After an exit, an opted-in worker gets up to three automatic restart attempts, delayed by 1, 2, and 4 seconds. Failed launches and failed readiness checks count against the same budget. Managed ingress is disabled while a dead worker recovers and resumes only after normal readiness checks pass. Other modules continue running.

The dashboard and AI module inventory report `recovering`, then `failed` if the budget is exhausted. Sixty seconds of continuous process uptime resets the budget; this is not an application health guarantee. An explicit `app start app/module` resets the budget. An explicit stop persists the stopped intent and prevents recovery. Failed restoration of one application no longer prevents restoration of other applications or startup of the management plane.

Restart counters are currently in memory and reset on runtime restart. Worker crash retries apply while the supervisor is alive. Supervisor death is handled separately by worker guardians and startup reconciliation, described below. Optional Linux cgroup resource limits are described in [resource controls](resources.md). Automatic cluster failover is not implemented.

Approved AI start/stop/restart/rollback operations record a receipt in `state/operations` before execution. If that initial write fails, the operation is not executed. Completion records success or failure without saving prompts, credentials, or raw error output. `ai operations` lists the latest 50 receipts, available even without provider configuration.

A receipt remaining in `started` is displayed as **unconfirmed**. It may describe an in-flight operation or an interruption between a side effect and the outcome write. Inspect current module state before retrying. Receipts are not a transaction log or an exactly-once job queue. Pending approvals remain session-bound, single-use, expiring, and in memory. Files are private to the runtime user, not tamper-proof against that user. State and receipt replacements now flush the private temporary file before rename and flush the containing directory afterward. A failed post-rename flush is treated as an uncertain commit, not permission to replay an operation. This does not guarantee survival of physical storage failure.

## Validation

CI uses Swift 6.2.3 on Linux and exercises unit/policy tests plus real OpenSSH, HTTP, WebSocket, crash recovery and restore. macOS release builds should start with `swift package clean` to avoid mixing cached clients with changes to Swift actor layouts. Run `swift build -c release`, then `KILN_BIN_DIR="$PWD/.build/release" python3 scripts/integration.py` before packaging.

Release 26.10.08.1 passed all 22 unit/policy tests on macOS and Linux x86_64, real SSH/REST/WebSocket recovery and restoration on both, managed deployment/rollback under 414 concurrent encrypted requests on macOS, and live Erebine proposal/approval/replay checks on macOS. Shutdown signal handling is installed before services become reachable, fixing a startup/stop race discovered by the Linux integration test.

The local console uses nonblocking stdin and a bounded command queue. A blocked libc `readLine` previously prevented Linux process exit with stdin still open; the integration test checks that this mode shuts down cleanly too.


## Unclean supervisor restart

Each direct application worker has a separate Swift guardian, launched through the same `kiln` executable. The supervisor owns a lifetime pipe. If the supervisor exits or is killed, the guardian observes EOF, terminates its exact child, escalates to SIGKILL after three seconds if needed, and reaps it. No saved PID is used to kill a process. Workers start with an empty signal mask and default SIGTERM/SIGINT dispositions restored, so they can install graceful shutdown handlers even when the supervisor uses Dispatch signal sources.

Guardians hold a shared ownership lock until reaping completes. Startup waits for exclusive access before restoring desired applications or exposing SSH. A guardian that starts late checks the lifetime pipe after acquiring the lock and cannot spawn an abandoned worker. If ownership cannot be cleared within ten seconds, startup fails instead of risking duplicate workers. A second supervisor using the same state directory is rejected.

This is restart recovery, not connection migration: supervisor death closes ingress connections. Clients reconnect after restoration. The separate remote-terminal service has its own lifetime; a whole-host reboot ends its remote sessions.

## Interrupted release and restart rules

`applications.json` is the authoritative active/previous release and desired-running index. A staging marker is written before creating a release directory. The executable and directory chain are flushed before the active index is committed.

- Before a deployment commits, recovery retains the prior active release and removes the uncommitted staging directory.
- After the index commits, recovery starts the new active release, even if the old supervisor died during traffic switching or draining. The previous release remains available for rollback.
- An explicit stop persists stopped intent before terminating the worker.
- Restart persists running intent before terminating the old worker, so an interruption does not accidentally become a permanent stop.
- If a post-rename persistence failure leaves commit durability uncertain, mutations fail closed and state reports recovery required. Referenced release files are retained for restart reconciliation.

Background AI tasks left queued/running become interrupted and are not automatically replayed. Completed results remain available. Approved operations without a recorded final outcome remain unconfirmed; inspect actual state before taking another action.

## Boundaries

The guardian owns a direct worker, not an arbitrary process tree. For legacy unconstrained workers, deliberately daemonized descendants and external SIGKILL of the guardian itself are outside this mechanism. Linux resource-constrained workers also use an owned cgroup and generation ledger for descendant cleanup and guardian-loss recovery. Modules remain trusted programs sharing Kiln's OS user. Resource quotas do not provide malicious-code isolation.

Upgrade a pre-guardian release with one graceful shutdown; this release does not discover or kill unknown processes left by older releases. Embedded users of `KilnRuntime` must distribute the matching `kiln` guardian executable beside their host executable.

`deploy/kiln.service` provides Linux boot startup and bounded supervisor restart. Its control-group shutdown also stops the separate terminal service; full service restart does not preserve those terminals. See [Linux service setup](linux-service.md).


## Repeatable recovery and storage-fault workload

Run `KILN_BIN_DIR="$PWD/.build/debug" KILN_SOAK_CYCLES=5 python3 scripts/crash-recovery-integration.py` after building. Both macOS and Linux CI run five cycles; the environment setting accepts 1–30 cycles for a longer disposable local run. The fixture owns its loopback ports, SSH identity, state and workers and never restarts an operator's node.

Each cycle keeps two clients issuing HTTP requests and WebSocket echoes, restarts the REST worker three times, then SIGKILLs the supervisor and starts a replacement. Disconnects during termination are expected and counted. A restored generation must serve at least five more successful requests of each protocol; malformed responses and HTTP error statuses fail. Settled state must contain exactly three workers and three guardians, no previous worker PIDs, a closed explicitly stopped worker port, unchanged host identity and Vault ciphertext, and preserved stopped intent. Existing candidate/draining deployment and ownership checks run afterward.

The fixture reports successful traffic counts, disconnects, supervisor descriptor/socket counts and captured worker-log bytes for each cycle. Descriptor limits are relative to the initial healthy supervisor: at most 24 extra descriptors/12 sockets during the two-client workload, and 16/8 after restoration. Captured worker logs must each remain within 4 MiB, with at most eight files for this workload; the fixture's own supervisor log must remain within 8 MiB. These are regression budgets, not production connection quotas or proof of a long-duration memory soak. Application-created data files remain outside captured-log limits.

The Swift state-file tests inject `ENOSPC`, `EACCES` and `EIO` outcomes at internal transaction checkpoints before writing and before rename. They verify the previous committed bytes survive and temporary files are removed. A separately seeded partial transaction is never promoted by the next write. An injected directory-flush failure after rename must report `CommitUncertain` while the replacement bytes are visible, requiring reconciliation rather than blind replay. The internal seam has no CLI/environment switch.

This evidence models filesystem failures; it does **not** fill a disk, change host permissions, interrupt a real kernel write, simulate device power loss, or establish durable storage guarantees. The fixture performs real process SIGKILLs but does not reboot the host. Actual bounded-filesystem exhaustion, physical power-loss behavior and extended soak durations remain separate validation work.
