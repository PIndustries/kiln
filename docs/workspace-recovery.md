# Owned code-workspace recovery

Registered development workspaces automatically checkpoint editor state under the
runtime state directory in `code-workspaces/`. Records belong to an authenticated
identity and application/module pair. They are independent of released source,
application manifests, provider accounts, and Git hosting.

The checkpoint includes unsaved text with its original source and hash, selected
file, caret, scrolling, wrapping, Vim preference and pane proportion. Reopening
Codebase restores the checkpoint and attaches to the newest active worker for
that identity and workspace. Vim editing restores in NORMAL mode. Other active
workers remain available through `ai work list` and `ai work watch ID`.

Saves debounce for 500 ms. SSH disconnect also flushes the final state, including
changes made while an earlier save was in flight. A process or machine crash can
lose changes made since the last successful checkpoint. Worker restart marks work
interrupted; it does not resume inference or replay a publication.

Source that changed or disappeared after a checkpoint does not silently replace
the recovered base. The editor retains the draft and warns about the different
base. Publication still uses the original hash and must pass the existing source
and deployment checks. Recovery alone never writes application source.

## Conflicting connections

Each save carries an expected revision. A stale connection cannot overwrite the
newer checkpoint. Its attempted state is retained as a separate private conflict
copy, and that connection stops automatic saves with a visible error.

For an administrator inspecting `web-demo/live`:

```text
web workspace web-demo/live App.swift
web workspace-conflicts web-demo/live
web workspace-recover web-demo/live COPY-ID EXPECTED-REVISION
```

The first command returns the current workspace record, including its revision.
The second lists conflict IDs for this identity and app. Recovery explicitly
replaces the checkpoint at the supplied revision; it does not merge drafts or
publish them. Close stale workspace connections before recovering, inspect the
saved drafts, then reopen Codebase. A further revision change rejects recovery
instead of overwriting another writer.

Files are written atomically with fsync and mode 0600 inside owned, private,
symlink-free directories. Locks serialize writers across runtime processes.
Recovery buffers use the registered editor's file and size limits. Conflict
retention is bounded; if full, export local edits before closing the connection.
Conflicts are retained after recovery for deliberate operator cleanup. They may
contain unpublished proprietary source and belong in private state backups.

## Local verification

```sh
swift test --build-system native --force-resolved-versions --jobs 4
python3 scripts/check-dependencies.py
python3 scripts/code-chat-acceptance.py
```

The SSH acceptance requires macOS and Python `pyte`. It uses a disposable runtime
and injected test provider. It disconnects during inference, restores an unsaved
draft and divider, automatically reattaches work, supplies more context, and checks
that application source and the running web worker did not change. It does not
prove live-provider behavior, power-loss durability or hosted CI acceptance.
