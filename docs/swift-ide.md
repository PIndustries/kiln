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
| F9 / Refs | Compiler-indexed project references; any document-only fallback is labelled |
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
execution. Kiln builds a project index on demand with the registered compiler,
then reads its public IndexStore API through Kiln's own C adapter. The installed
`libIndexStore` is a Swift toolchain primitive; no IndexStoreDB package or hosted
index service is added. Index compilation has unique outputs per source file,
ignores system/Clang module indexing, includes local symbols, and never runs the
compiled application. Its entire process group is stopped on cancellation or
timeout. Temporary objects/index files are discarded after reading.

Cached records match an exact source-content fingerprint within the authenticated
language session. Compiler symbol identities resolve cross-file references and
rename targets, preserving unrelated shadowed names, strings and comments.
Compiler failures and reader/record limits fail explicitly instead of serving
partial or older project results. The control result's `coverage` field says
`project` or `document`. If a symbol has no supported indexed identifier, SourceKit
can still provide a labelled document-only result. Project rename cannot alter
SDK/generated definitions or known override relationships. It is an editable
proposal, not proof of behavior equivalence; review it before publishing.

The current index resource guards are 30 seconds of compilation, 64 KiB compiler
diagnostics, 4,096 units/record dependencies, 200,000 raw occurrences, and 100,000
deduplicated occurrences/16 MiB retained metadata per session. IndexStore UTF-8
columns are converted to editor UTF-16 positions. Test navigation, formatting/code
actions, deeper override/protocol refactoring and LLDB/DAP remain separate work.

The real SourceKit test in `SwiftIDETests` is enabled with
`KILN_SWIFT_IDE_SDK=/path/to/pinned-sdk.json`. It checks session reuse, document
versions, owner/connection isolation, process restart, cancellation recovery,
diagnostics, references and rename proposals while source remains untouched.
`scripts/swift-ide-acceptance.py` exercises the actual SSH UI against disposable
source and runtime state, including compiler errors, wrap and deployed-run
controls. Neither test uses model accounts or mutates the user's development app.
