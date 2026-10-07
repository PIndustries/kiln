# Servers, terminal sessions and split panes

Kiln keeps remote SSH connections in a separate native session-service process. The SSH dashboard is a viewer. Disconnecting or restarting the dashboard leaves the remote PTYs, shell environments and terminal screens running in that service.

## Set up a server entirely through menus

Open **6 Servers** (6 SSH on narrow terminals), then press **n** or click **Add server**. Fill Name, Host, User and Port; Tab/Up/Down moves between fields, Enter advances/saves, Escape cancels. Fields support cursor movement, Home/End, deletion and paste.

Select a server and press Enter or click its row:

- **Edit server:** changing the host or port clears its saved host-key trust. Existing sessions keep their original connection.
- **Generate and assign key:** create an Ed25519 key in macOS Keychain. Install the displayed public key in the destination user's authorized_keys using your existing administration channel. Kiln does not automatically install it or ask for the destination password.
- **Assign existing key / Show public key:** select a previously generated key or display its public half.
- **Scan host key:** collect an unverified Ed25519 fingerprint.
- **Verify host key:** compare the fingerprint with a trusted source, then enter that verified fingerprint. A scan alone never grants trust.
- **New terminal:** name the session, connect and attach.
- **Remove server:** confirmation is required. This blocks new connections; existing terminals are unchanged.

Only public metadata crosses the dashboard/service socket. Private keys stay in Keychain and are retrieved into the session service's memory for authentication. The existing single-admin and trusted-module boundaries still apply; this is not isolation from hostile code under the same OS account.

## Session picker and actions

Open **5 Sessions** (5 TTY on narrow terminals). **n / New terminal** opens a server picker and name form. Enter/click on a session opens **Attach**, **Rename**, and **Close session**. **a** attaches directly. Rename requires a detached session. Closing a running session requires a separate confirmation; Cancel is selected initially.

The command drawer exposes the same operations:

```text
session new work staging
session attach work
session rename work development
session list
session close development
```

`session new` creates without attaching; `session open <name> <server>` creates and attaches from the interactive dashboard. Only one viewer can own a terminal's input. Another viewer cannot silently steal it. Shell exit retains its last screen/exit state until the session is explicitly closed.

## Keyboard and mouse controls

Within a terminal, press **Ctrl-B**, release it, then:

| Key | Action |
| --- | --- |
| d or w | Detach all visible panes and return to the session picker |
| n / p | Switch the focused pane to the next/previous available session |
| % | Split side-by-side with another detached session; change an existing split to side-by-side |
| " | Split top/bottom with another detached session; change an existing split to stacked |
| o | Cycle pane focus |
| h / l | Decrease/increase the first pane's share of the viewport |
| x | Return the focused pane to full window; detach the other terminal without closing it |
| Ctrl-B | Send a literal Ctrl-B to the remote program |

Click inside a pane to focus it. The focused pane has a blue status bar. Split layouts currently contain two terminals; create another terminal before splitting. Split selection uses the next available detached session. Unrecognized prefix combinations are sent through. Layout/focus belong to the viewer and are not restored after it disconnects; the terminals themselves remain available in the picker.

To disconnect from Kiln without ending terminals, detach and press q. Connect again and attach through **5 Sessions**.

## Session-service lifetime

`kiln up` starts or reconnects to the session service for its state directory. It runs the same executable in `session-service --state PATH` mode with a separate lifetime and lock. Communication uses a Unix socket under an owner-only directory in `/tmp` (0700 directory, 0600 socket), with bounded length-prefixed JSON messages. It does not open another TCP listener or transmit private keys over IPC.

Stopping or killing the dashboard **does not stop the service**. Viewers normally release ownership on disconnect; after an abrupt dashboard crash, a six-second viewer lease expires. The service and remote shell survived both graceful dashboard restart and SIGKILL in integration tests. Dashboard/service compatibility is checked using protocol version 1; changing that protocol requires an explicit service upgrade.

To intentionally stop the service and all its terminals:

```sh
./kiln session-service-stop --state /absolute/path/to/state
```

Use this before removing a state directory. Ending a session service, rebooting its host, or losing the outbound SSH connection ends the associated sessions. There is no checkpointing, distributed migration or automatic recreation of a lost shell. A compatible dashboard can be replaced independently; upgrading the session service itself currently ends its terminals.

## Terminal implementation and current limits

SwiftNIO SSH owns connections and PTYs; SwiftTerm retains normal and alternate screen buffers. Views are reconstructed from cells, colors and cursor state rather than replaying a suffix of escape sequences. Resize propagates each pane's dimensions to its remote PTY, reserving one row for controls. A slow viewer receives current frames rather than accumulating an unbounded output queue.

Up to 16 terminals are allowed per service. Each has a 200,000-cell viewport limit and up to 1,000 retained history lines, reduced for wide terminals. Frames are pulled at up to 10 Hz. Buffers remain in memory; Kiln does not save terminal transcripts to disk. Full-screen output, colors, independent input and resizing are verified against a local OpenSSH server. Remote application mouse reporting, a history/copy mode, terminal graphics, clipboard forwarding and arbitrary split trees are not implemented.

This is still a development bastion: sessions are shared by the current privileged administrator identity, with no per-person RBAC or durable connection audit trail.

## Verification

With Python `pyte` installed, run:

```sh
python scripts/sessions-integration.py
python scripts/workflows-integration.py
```

Tests launch a temporary loopback OpenSSH destination, create/delete a temporary Keychain key, and explicitly stop their separate session services. The workflow suite covers menu-only server/key/trust setup, two remote terminals, both split layouts, mouse/keyboard focus, pane sizing, disconnect/reconnect, screen and environment preservation, clean/abrupt dashboard restarts, rename, cancel/confirm close, trust reset after editing, and confirmed server removal.
