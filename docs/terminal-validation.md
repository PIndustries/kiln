# Terminal validation

The automated checks below run without provider credentials or inference charges.
They cover different boundaries; passing the renderer fixture does not establish
that every SSH client or terminal emulator behaves identically.

```sh
swift test
python3 -m venv /tmp/kiln-terminal-tests
/tmp/kiln-terminal-tests/bin/pip install -r scripts/terminal-test-requirements.txt
/tmp/kiln-terminal-tests/bin/python scripts/terminal-integration.py
```

`KILN_BIN_DIR` selects an already-built binary directory for Python scripts; the
default is `.build/debug`. They launch temporary local nodes and generated SSH
identities. Do not point them at a running node's state directory.

| Boundary | Repeatable coverage | What it does not prove |
| --- | --- | --- |
| Native HTTP/SSE → terminal frames | `OfflineTerminalStreamingTests`: delayed URLProtocol body deliveries through the real stream delegate/decoder and `KilnTerminal.render`; distinct partial frames before completion, one final answer, cancellation without late output, successful next request | Actual remote provider timing, SSH paint scheduling or network reconnection |
| Terminal interaction model | Offline tests plus `TerminalAIWorkspaceTests`: refreshed task state, mouse/keyboard exact approval review, approve/deny effects, expired/removed/busy rejection, narrow layout, revoked-role snapshot cleanup, selection controls, scrollback and resize | Backend authorization execution or OS clipboard integration |
| Bounded retries | `ProviderFailureTests`: typed 429 handling, exhausted/cancelled waits, no retry of quota/unknown errors or partial streams | Live provider capacity or billing availability |
| Real OpenSSH PTY | `scripts/terminal-integration.py`: mouse input, anchored service menus, confirmation, metrics refresh, drawer, resize and reconnect using OpenSSH + pyte | Native terminal emulator selection/clipboard or additional SSH clients |
| Live optional AI | `scripts/ai-terminal-integration.py` and `scripts/ai-workspace-integration.py`: configured-provider chat/tasks/approvals through real SSH | Offline deterministic behavior; these require credentials and may consume credits |

## Recorded local check

On macOS arm64 with OpenSSH 10.3p1 and pyte, the real PTY regression script
also passed. The delayed offline fixture delivered five distinct partial answer
frames, then one completed answer. Cancellation stopped further progress callbacks;
a replacement request completed. The tests also exercised 120/150-column and
80-column layouts at 24/30 rows, task status refresh and stale approval removal.
The fixture uses only a reserved `.invalid` URL intercepted by URLProtocol: no
production HTTP exception, fake credential, or runtime test-provider switch exists.

Keep issue #9 open until the broader client matrix is recorded. Remaining checks
include real SSH cancellation/approval interactions against a deterministic provider
fixture, SSH reconnection during an active stream, native emulator clipboard
selection, and additional clients beyond OpenSSH/pyte. The pure selection test
checks input suppression; actual frozen screen painting is a transport concern.
