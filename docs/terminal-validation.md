# Terminal validation

The automated checks below run without provider credentials or inference charges.
They cover different boundaries; passing the renderer fixture does not establish
that every SSH client or terminal emulator behaves identically.

```sh
swift test
python3 -m venv /tmp/kiln-terminal-tests
/tmp/kiln-terminal-tests/bin/pip install -r scripts/terminal-test-requirements.txt
/tmp/kiln-terminal-tests/bin/python scripts/terminal-integration.py
/tmp/kiln-terminal-tests/bin/python scripts/offline-ai-terminal-integration.py
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
| Offline provider → real OpenSSH PTY | `scripts/offline-ai-terminal-integration.py`: normal local Ollama HTTP route, delayed answer frames, frozen screen during incoming output, cancellation/follow-up, real tool calls, mouse deny/keyboard approve with actual worker PID checks, foreground disconnect/reconnect and cleared session proposals | Erebine retry scheduling, native OS clipboard, remote provider quality or real account acceptance |
| Live optional AI | `scripts/ai-terminal-integration.py` and `scripts/ai-workspace-integration.py`: configured-provider chat/tasks/approvals through real SSH | Offline deterministic behavior; these require credentials and may consume credits |

## Recorded local check

On macOS arm64 with OpenSSH 10.3p1 and pyte, the real PTY regression script
also passed. The delayed offline fixture delivered five distinct partial answer
frames, then one completed answer. Cancellation stopped further progress callbacks;
a replacement request completed. The tests also exercised 120/150-column and
80-column layouts at 24/30 rows, task status refresh and stale approval removal. A deterministic capacity-retry
fixture also verifies the 2s/1s countdown, task refresh during backoff, rejection
of busy approval clicks, and exact-operation review after completion.
The fixture uses only a reserved `.invalid` URL intercepted by URLProtocol: no
production HTTP exception, fake credential, or runtime test-provider switch exists.

The offline OpenSSH fixture passed on macOS arm64 on 2026-10-23. It uses a
temporary loopback HTTP server through the ordinary Ollama transport, without
production test-provider switches or credentials. A foreground disconnect starts
a new conversation on reconnect: no old history or session proposal is restored.
Its successful tool exchange and metrics check run after reconnect.

Keep issue #9 open for native emulator clipboard selection, additional clients
beyond OpenSSH/pyte, and actual Erebine retry/sidebar behavior through SSH.
The new fixture proves frozen painting during incoming stream content, while
clipboard integration remains a separate OS-level check.

## Live provider check (2026-10-11)

The maintainer's PR #32 binary also passed the opt-in live Erebine + OpenSSH/pyte
terminal script on macOS: 44 distinct activity frames, 13 partial answer frames,
and 10 animated waiting frames. Selection mode stayed visually frozen, and a
background task survived the SSH viewer disconnect with its result available after
reconnecting. The live command integration also checked proposals, approval,
single-use replay rejection and background tasks.

This is live provider evidence, not deterministic offline SSH coverage. It does not
claim native OS clipboard behavior or that an in-progress foreground answer resumes
after reconnect. These scripts use a temporary node copied from explicitly supplied
provider configuration; do not run them implicitly in CI or without authorization to
consume inference credits.

## Fresh live Erebine check (2026-10-23)

The native OpenSSH/pyte chat suite passed with 118 activity frames, 24 distinct
partial-answer frames and 11 waiting frames. Selection stayed frozen and a
background task survived disconnect. The workspace suite passed mouse denial
without a worker change, keyboard approval with a changed worker PID and consumed
proposal, live background task completion, and narrow-terminal Tab navigation.
The delayed offline SSH fixture separately verifies that backtick opens the
command drawer from chat and after Escape, and `status` executes as a CLI command.

Native clipboard copying was not verified: the available native automation lacked
Accessibility permission or blocked Terminal. These results do not close the
broader native-client matrix or actual Erebine retry/sidebar acceptance gate.
