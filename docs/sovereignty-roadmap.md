# Kiln sovereignty and development-platform roadmap

Direction: Kiln owns its product architecture. Other frameworks inform designs;
they are not selected as mandatory replacements for Kiln's implementation.
Portable bundles remain deferred. This document is a scope and acceptance contract,
not a claim that the milestones below are delivered.

## Ownership boundary

Kiln owns workspace/document storage, agent scheduling and event history, tool
permissions, editor integration, native Swift views, templates, live application
protocol, persistence/authentication contracts, and release/rollback policy.
No mandatory SaaS, hosted agent controller, external workflow engine, or external
MVC framework is added. Existing SwiftNIO/SSH, Swift Crypto and SwiftTerm are
explicitly inventoried implementation primitives, not silently treated as our
source. SourceKit-LSP and LLDB remain replaceable Swift toolchain integrations.

Retaining these primitives does not make the system dependency-free. The goal is
operational control, inspectable source, reproducible revisions, owned data and
replaceable boundaries. Do not invent new cryptography or SSH implementations
merely to change the ownership label. A future replacement must have its own
threat model, interoperability tests and maintenance plan.

`config/dependency-policy.json` records current direct sources and every resolved
source revision. Run `python3 scripts/check-dependencies.py` offline. A dependency
change must include a deliberate policy update and rationale in the code review.
The check detects drift; it is not a vulnerability or license audit. Offline
source mirrors and clean-machine reproducibility still need explicit validation.
Provider integrations are optional. Kiln must retain provider-independent control
and a self-hosted inference path; model availability and external account terms
are not properties Kiln can guarantee.

## Milestones and acceptance

1. **Durable owned workspace.** Owner/app-scoped identity; restore unsaved buffers,
   source bases, caret, scroll, wrapping, Vim preference and pane proportion.
   Compare-and-swap saves and recoverable conflicting copies. Reattach running
   workspace agents automatically. Test disconnects while a save is in flight,
   changed/deleted source, two clients, revocation and filesystem failure. A
   recovery save never publishes an app or silently rebases a draft.
2. **Durable agent events.** Ordered local event journal for messages, consumed
   context, tool decisions, proposed patches, validations, operation IDs and
   authoritative receipts. Separate queued/consumed/applied acknowledgements.
   Reconcile interrupted work and uncertain side effects before offering resume.
   Never replay a publication just to reconstruct the interface.
3. **Persistent Swift tooling.** Owned lifecycle of isolated SourceKit sessions,
   document versions, cancellation, diagnostics, symbols, references, rename,
   formatting and code actions. Test stale replies and process restarts. Add
   LLDB/DAP and navigable Swift tests. Broader SwiftPM projects require explicit
   package/plugin trust, not relaxed sandboxing.
4. **Coordinated 48-agent work.** Isolated per-agent source snapshots/branches,
   bounded shared compiler resources, task dependencies, review and integration
   queues. Keep one guarded publication per app generation. Prove overlapping
   edits, cancellation, conflict resolution, independent work and overload with
   real scenario tests; do not call a capacity fixture multi-agent acceptance.
5. **Evidence-driven agent capabilities.** Registered source/symbol search,
   scoped build/test execution and development-browser assertions. Typed tool
   discovery reflects the actual grant. A successful task includes behavior
   evidence, not just compilation or HTTP 200. Replace fixed turn-count stopping
   with completion/progress/cancellation policies and explicit resource guards.
6. **Owned live MVC lifecycle.** Stable component identity and incremental DOM
   updates; form validation, errors, uploads, focus/selection/scroll restoration,
   reconnect semantics and component/interaction tests. Native Swift views remain
   primary; HTML templates share layout, escaping and application contracts.
7. **Owned application foundations and proving app.** Explicit storage adapter
   and transaction contracts, migrations, application authentication/authorization,
   assets, uploads and jobs. Keep app identities separate from Kiln operator
   identities. Build a persisted issue tracker with live updates to exercise the
   framework. Do not equate code rollback with reversing database changes.
8. **Stable interfaces and interoperability.** Versioned owned control/event API
   shared by terminal and future graphical clients. Protocol adapters (LSP, DAP,
   optional ACP/MCP) are replaceable boundaries, not required third-party services.
   Validate reconnect, access revocation and client-version compatibility.

## Release bar

Open app, edit locally, start agent, observe proposed code/diff, steer, disconnect,
restore workspace, run tests, verify browser behavior, publish, inspect the receipt,
and roll back safely. Include injected crash/conflict/cancellation scenarios.
Record local tests, hosted validation and live deployment separately. No framework
or IDE maturity claim is based on unit-test count alone.

## Current local evidence

The owned workspace checkpoint/recovery path and ordered background-agent journal
are implemented. See [workspace recovery](workspace-recovery.md) and
[agent events](agent-events.md) for their actual behavior, guards and limitations.
The agent-event iteration passes 328 local tests, real SSH code/chat recovery and
steering, and a forced process-kill/new-process recovery harness without replay.
These are foundation milestones, not acceptance of all eight areas above. Hosted
validation, live-provider publication after the event update, operation-aware
reconciliation UX and the remaining Swift/coordination/framework work are still
separate gates.
