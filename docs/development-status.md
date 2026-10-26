# Kiln development status

Kiln combines a modular Swift runtime, a terminal development workspace, native
server-rendered web applications, and optional AI provider integrations. This page
separates implemented capabilities from current development and validation limits.

## Implemented capabilities

- **Runtime and services:** application/module identities, separate worker
  processes, service health, logs, retained releases, and guarded rollback.
- **Web applications:** native Swift views, MVC routing/controllers, HTML
  templates, CSS customization, and local development publication.
- **Swift workspace:** file browsing/editing, syntax highlighting, Vim interaction,
  configurable wrapping and horizontal scrolling, resizable code/chat panes,
  completion, definition navigation, diagnostics, isolated builds, references,
  draft rename proposals, formatting, and compiler-action draft edits.
- **Workspace recovery:** scoped draft storage, compare-and-swap saves, conflicting
  recovery copies, and reconnection to running workspace agents.
- **Background agents:** independent chat, up to 48 concurrent workers, live source
  following, context delivery at safe steps, ordered event journals, scoped source
  snapshots, and per-application integration queues.
- **Change review:** retained source history, colored diffs, current/base/proposed
  source views, stale-review rejection, and explicit multi-file staging into local
  drafts that preserves existing edits.

See [Swift IDE](swift-ide.md), [web framework](web-framework.md),
[workspace recovery](workspace-recovery.md), and [agent events](agent-events.md)
for supported workflows and their limits.

## Current core development

- Navigable Swift test results and build/test controls.
- Agent concurrency, cancellation, reconnect, and conflict-handling refinements.

Portable application bundles are outside the current core milestone.

## Validation boundaries

Local tests cover isolated compiler/language-service sessions, draft recovery,
source checks, agent queue ordering, cancellation, and interrupted-work handling.
OpenSSH acceptance exercises the split workspace, context delivery, reconnects,
source publication, proposal review, and local draft staging.

Deterministic provider fixtures establish controller behavior; they do not certify
every external provider or account. A successful compile or HTTP response does
not establish browser interaction correctness. Source rollback does not reverse
application database changes. Hosted workflow results, local validation, and a
running development preview are separate evidence.

The full development journey includes editing, steering an agent, recovering a
disconnected workspace, building, checking application behavior, publishing,
inspecting the release receipt, and rolling back safely. Validation includes
conflicts, cancellation, and interrupted operations. Publications are never
replayed solely to rebuild an interface.

## Dependencies and interfaces

Kiln implements workspace storage, agent lifecycle, editor integration, views,
and release policy in this repository. The dependency inventory lists the Swift
networking, SSH, cryptographic, and terminal primitives used by those components.
SourceKit-LSP and the compiler index are interfaces to the installed Swift
toolchain. Their availability and behavior depend on that toolchain.

`config/dependency-policy.json` records direct sources and resolved revisions.
Run `python3 scripts/check-dependencies.py` for an offline inventory check.
Dependency changes include an inventory update and review rationale. This check
detects inventory drift; it is not a vulnerability or license audit. Clean-machine
reproducibility and offline source mirrors require their own validation.
