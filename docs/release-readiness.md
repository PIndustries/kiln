# Release readiness

Kiln remains private while the server foundation is being hardened. Passing tests is evidence for a defined release, not a claim that every planned ecosystem feature is complete. Keep source commits, packaged binaries, CI runs and deployed versions identifiable.

## Required gates for each server release

1. Build from a clean checkout using the pinned dependency resolution and the documented Swift version on macOS and Linux. Run unit/policy tests and real OpenSSH/HTTP/WebSocket integrations.
2. Exercise worker and supervisor death, interrupted deployment and rollback, stopped intent, host identity preservation and ownership cleanup. Use a disposable systemd/cgroup v2 host for hard resource enforcement.
3. Verify identity revocation and module scopes through SSH, terminal actions and AI tools; test denied operations and persistent audit intent/outcomes.
4. Exercise bounded network admission, stalled authentication, oversized input, disconnected peer operations, duplicate requests and receipt reconciliation. Overload must reject work without claiming an unconfirmed operation did not happen.
5. Verify secret provisioning, encrypted reopen, grants/revocation and failed initialization. A failed persistence acknowledgement must preserve recovery material rather than discard possibly committed state.
6. Verify bounded logs, log-flood behavior, overlapping generations and teardown when descendants retain standard output. Diagnostic storage failure must not prevent ownership cleanup.
7. Test the exact packaged binary; record its source commit, checksums, platform and actual results. Verify existing applications after upgrade. Keep a compatible recovery binary and backups of state and separately stored Vault keys.

The opt-in Erebine tests use a real provider and can incur charges. Run them for changes to AI transport, tool authorization, streaming, task lifecycle or the SSH chat interface. Unit tests alone do not prove live-provider interoperability.

## Current operating boundaries

- Application executables are trusted. They share Kiln's OS user; management roles, encrypted Vault storage and cgroup budgets do not create a hostile-code sandbox.
- Worker output capture has bounded storage and may drop chunks under lock contention or storage failure. It is not a lossless audit service or a general filesystem quota.
- Management SSH admits at most 128 parent connections, 16 child channels per connection and 256 child channels globally. Authentication must finish within 15 seconds, with at most 128 KiB of pre-authentication bytes and six authentication delegate requests. Excess connections/channels close or are rejected. These are conservative fixed server limits, not configurable tenant quotas or distributed rate limiting.
- Each managed ingress listener admits at most 1,024 simultaneous TCP connections. Existing connections retain their original backend generation. There is no automatic request retry or migration of arbitrary stateful connections.
- Peer adoption permits narrowly typed administrative operations. Admission limits include dispatched work whose client has disconnected. Consensus, fencing, automatic workload placement/failover and replicated storage are not implemented.
- Hard module budgets require delegated Linux cgroup v2. macOS rejects requested hard limits. Application-created files, release storage and network traffic are not quota constrained.
- Live connections do not survive node death. Background AI task records persist; foreground chat history and pending approvals do not.

## Before changing repository visibility

Review the current tree and Git history for credentials, private endpoints, customer information and third-party redistribution obligations. Select the project's license with P.Industries, add contribution/reporting policies, and document the supported deployment matrix and upgrade/recovery procedure. No license choice or public announcement is implied by this stabilization work.

An initial open-source release should advertise only the verified capabilities above. Public ACME/TLS ingress, Cloudflare/Resend integrations, source-build delivery, replicated storage, appliance images and native Apple clients require their own implementation and acceptance gates; documentation must not present them as shipped.
