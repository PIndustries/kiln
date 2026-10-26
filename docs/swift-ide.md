# Native Swift IDE services

Kiln owns the editor, private source snapshots, language-process lifecycle,
document versions, result validation and publishing controls. SourceKit-LSP is a
replaceable Swift-toolchain integration. No additional IDE framework, hosted
language service or package dependency is required.

## Controls

| Control | Behavior |
| --- | --- |
| Type / Ctrl-Space | Automatic / explicit completion; arrows select, Tab or Enter inserts |
| F12 / Def | Resolve a definition in registered project files |
| F9 / Refs | Semantic references; document-only fallback is explicitly labelled |
| F10 / Rename | Request a rename proposal, then Enter applies it to local drafts |
| F4 / Issues | Open clickable diagnostics for the current document |
| F11 / Build | Compile all current buffers in isolation |
| F5 / Run | Restart the deployed release after unsaved edits are resolved |
| Ctrl-D | Review confirmation and publish the edited files together |

Diagnostics refresh after typing and mark source line numbers. They do not replace
the editor or its completion popup. Scrolling and trackpad navigation remain
available while language reads are pending. A reply for older text is discarded;
diagnostics for unchanged text remain valid when only the caret moved.

Rename accepts a plain Swift identifier, not a complete function signature with
argument labels. SourceKit's edits are validated for registered paths, UTF-16
ranges, overlap and supported file operations. Versioned edits must match their
documents. Rename cannot create/delete files or edit generated templates, SDK
sources or another app. The proposal preserves existing unsaved buffers and their
original source hashes. Applying it changes drafts only. Publication still passes
isolated compilation, source hash checks, authorization and deployment generation
checks. Escape discards the proposal before applying it.

## Sessions and isolation

Language sessions are scoped to the authenticated identity, connection and app.
Each private session opens versioned documents once and sends full-text changes
when their contents change. It reuses the language process for later completion,
definition, reference, rename and diagnostic requests. Sessions from different
connections do not share unsaved document contents.

The runtime keeps at most four language sessions, evicts unused sessions when the
pool fills and retires them after two idle minutes. Active requests cannot be
evicted. Cancellation, timeout, process exit or protocol failure retires the
session; a subsequent request starts fresh. A changed SDK or file set also starts
a new session. These are compiler-resource guards, separate from the agent's
48-worker capacity and provider generation limits.

The language process runs with the existing macOS source-build sandbox over
registered text snapshots and a pinned SDK. No SwiftPM manifest, package plugin,
dependency fetch or user shell runs. Compiler flags come from the administrator's
registered SDK. Provider credentials and user environment are not passed through.
Build and run remain separate operations; requesting language information cannot
publish a source change or restart a service.

## Current boundaries

This is the registered-project IDE, not unrestricted SwiftPM/Xcode project
execution. The current compilation-database path has no maintained project-wide
index. If SourceKit returns no indexed references, Kiln uses its semantic document
highlights and labels the narrower coverage. It does not use textual matching as
symbol identity. Review rename proposals; compile validation remains mandatory
before publication. Native project indexing, test navigation, formatting/code
actions and LLDB/DAP are still separate work.

The real SourceKit test in `SwiftIDETests` is enabled with
`KILN_SWIFT_IDE_SDK=/path/to/pinned-sdk.json`. It checks session reuse, document
versions, owner/connection isolation, process restart, cancellation recovery,
diagnostics, references and rename proposals while source remains untouched.
`scripts/swift-ide-acceptance.py` exercises the actual SSH UI against disposable
source and runtime state, including compiler errors, wrap and deployed-run
controls. Neither test uses model accounts or mutates the user's development app.
