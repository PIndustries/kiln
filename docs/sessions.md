# Persistent terminal sessions

Kiln owns remote SSH connections independently of its inbound SSH viewers. Each named session has its own remote PTY, SwiftTerm screen state and shell environment. Closing a viewer or losing its network connection detaches it; remote output continues to update the retained screen.

## Start and switch

First configure a saved server, assign a Keychain key and pin its verified host identity as described in [bastion setup](bastion.md). The destination must accept SSH PTY and shell requests.

In the Kiln command drawer:

```text
session new work staging
session new logs staging
session attach work
```

`session new` establishes the connection without attaching. Open **5 Sessions**, select a row with arrows or the mouse, and press Enter/click to attach. Each terminal uses its own shell, including when several sessions connect to the same server.

Within a remote terminal, press **Ctrl-B**, release it, then:

| Key | Action |
| --- | --- |
| d or w | Detach and return to the Kiln Sessions picker |
| n | Switch to the next available session |
| p | Switch to the previous available session |
| Ctrl-B | Send one literal Ctrl-B to the remote program |

Unrecognized prefix combinations are forwarded to the remote terminal. To disconnect from Kiln without ending remote sessions, detach, then press q. Reconnect using your usual SSH command and open **5 Sessions** to resume.

```text
session list
session close work
session help
```

`session close` deliberately closes the outbound connection; a currently attached viewer returns to the picker. Typing `exit` inside the remote shell ends that shell. A finished session retains its last screen and exit state until closed. Only one viewer can own input for a session at a time; another attach is rejected rather than stealing it. Sessions are shared across the current single administrator identity, not isolated per person.

## Implementation and boundaries

- Native Swift/NIO SSH connections and the SwiftTerm terminal engine; no tmux daemon or exported private key files.
- The screen is reconstructed from terminal cells, colors and cursor state, rather than replaying an arbitrary suffix of escape sequences. Normal and alternate screen buffers remain in the session.
- Remote PTY dimensions follow the attached viewer, reserving its final row for Kiln controls. Detached sessions keep their last size. A 200,000-cell viewport limit bounds rendering work.
- Frames are pulled at up to 10 Hz. A slow viewer skips intermediate frames and receives the current screen once writable; remote output is not queued indefinitely for the viewer.
- Up to 16 sessions per runtime, with up to 1,000 retained history lines, reduced for wide terminals to bound cell storage. A user-facing history/copy mode is not implemented yet.
- This first version provides full-window switching and a picker, not split panes, shared simultaneous viewers, remote mouse reporting, terminal graphics, clipboard forwarding or complete tmux compatibility.
- **Sessions survive viewer disconnects while Kiln and the outbound SSH connection stay alive. They do not survive Kiln restart, host reboot, destination restart or loss of the outbound connection.** Kiln does not silently recreate a lost shell. Restart-independent ownership would need a separate persistent session service; distributed migration would require another design.
- Session buffers can contain sensitive remote output. They stay in memory and are not written as transcript files. Current trusted-module/single-admin security boundaries still apply.

## Verification

On macOS, run `scripts/sessions-integration.py` using Python with `pyte` installed. It launches a temporary local OpenSSH destination on loopback and creates/deletes a temporary Keychain credential. It exercises two independent shells, switching, abrupt viewer loss, retained environment/background output, alternate screens/colors, PTY resize, exclusive ownership, and explicit session closure.
