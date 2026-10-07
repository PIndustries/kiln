# Bastion and managed SSH

KilnBastion is a separate Swift target. Its server registry and key operations are exposed through KilnCommands, available in the SSH command drawer, SSH exec and local console. No runtime restart is needed to register a server or generate a key.

## Interactive jump sessions

Inside Kiln, register a destination (replace the example values):

```text
server add staging staging.example.com deploy 22
server list
server config staging
```

Adding a server authorizes SSH direct-TCP forwarding to that exact hostname and port. Every authenticated Kiln administrator shares this allowlist. DNS is resolved by the Kiln host; a hostname entry follows its current DNS result. A literal IP entry avoids that dependency. The registry does not restrict the destination SSH username for ProxyJump: the destination server enforces its own authentication.

On your client, configure `~/.ssh/config`:

```sshconfig
Host kiln
  HostName 127.0.0.1
  Port 2222
  User admin
  IdentityFile ~/.ssh/id_ed25519

Host staging
  HostName staging.example.com
  User deploy
  Port 22
  ProxyJump kiln
  IdentityFile ~/.ssh/staging_ed25519
```

Then `ssh staging` opens a normal interactive SSH session through Kiln. Your SSH client authenticates the destination and verifies its host key; the destination private key stays on your client. Agent forwarding is not needed. The local default listener is loopback only; configure network exposure separately when deploying to another host.

`server remove staging` denies new tunnels. Existing tunnels remain open. Unknown destinations are denied. Reverse forwarding and SSH agent forwarding are not implemented. A registered destination is a TCP allowance; it is not an SSH-only protocol filter.

## Kiln-managed keys and commands

Run in Kiln:

```text
key create staging-key
key public staging-key
server key staging staging-key
server scan staging
```

Install the displayed **public** key in the destination user's authorized_keys using your existing administration channel. No private key export is provided. `server scan` collects an untrusted Ed25519 host key; independently verify its SHA256 fingerprint on the destination or with its administrator, then:

```text
server trust staging SHA256:<verified-fingerprint>
server exec staging 'uname -a'
```

The native Swift SSH client requires the pinned host key and uses the assigned private key from macOS Keychain. A mismatch fails closed. Commands have a 15-second deadline and a combined stdout/stderr limit of 64 KiB. The quoted command is executed by the destination's SSH service under the saved user. This is command execution, not an embedded interactive terminal or file-transfer client.

Keys are non-synchronizing Keychain items; only public keys, server profiles and host pins are written to `bastion.json`. Keychain access failures return an error without falling back to plaintext files or prompting through a remote session. Private material is retrieved into process memory for authentication. macOS Keychain may require local authorization after a binary replacement; unattended access while locked and signed release upgrades have not been verified. Linux managed key storage is unavailable and fails closed.

```text
key list
server remove staging
key delete staging-key
```

Remove references before deleting a key. Back up public registry metadata separately from credentials; copying Kiln's state directory does not transfer Keychain items to another machine.

## Current trust boundary

This is a development bastion, not a production credential vault. All accepted SSH keys authenticate as the same privileged administrator. There is no per-person/per-server RBAC, durable audit trail, credential rotation policy, password storage or distributed secret replication. Installed applications run under the supervisor's OS account; that is not a security boundary against malicious applications. Use only trusted modules. Process isolation limits crashes, not credential access by hostile code under the same account.

The SSH relay derives from Apple's SwiftNIO SSH example, with its Apache 2.0 license retained in `docs/licenses/swift-nio-ssh.txt`.
