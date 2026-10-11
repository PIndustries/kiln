# SSH authentication and admission

Start with one explicit key, bypassing your SSH agent and per-host configuration:

```sh
ssh -F /dev/null -o IdentitiesOnly=yes -o IdentityAgent=none \
  -i ~/.ssh/id_ed25519 -p 2222 admin@127.0.0.1
```

Verify the server host fingerprint before accepting it. Use the named user that owns
that public key in Kiln's identity policy. The startup authorized-keys file seeds
that policy only on first initialization; editing it later does not change users.
An administrator manages existing users with `identity` commands.

If the explicit-key command works but your usual command fails, use `ssh-add -l`
to list agent key fingerprints and `ssh -G your-host` to inspect effective client
settings. Add `IdentitiesOnly yes` and a specific `IdentityFile` to that host's SSH
configuration. Use `ssh -vv` locally to see key-offer order; redact usernames,
addresses, paths and fingerprints before sharing client output. Do not paste keys.
A stalled signing agent can consume the entire authentication deadline; use
`IdentityAgent=none` with a local key to distinguish it from a server outage.

## Server diagnostics

Kiln writes fixed reason codes to stderr, captured by your service manager or the
log destination used to start `kiln up`. Each line has an opaque connection ID and
a count of suppressed records. It contains no client username, address, public
key, credential, command or raw parser error.

| Reason | Meaning |
| --- | --- |
| `identity_rejected` | The offered identity is not authorized; deliberately does not distinguish unknown user, key mismatch, or revoked policy. |
| `method_rejected` | The client requested a method other than public-key authentication. |
| `authentication_budget` | More than six authentication requests; too many agent identities can exhaust this budget. |
| `authentication_timeout` | Authentication did not complete within 15 seconds, including negotiation and agent signing. |
| `preauthentication_bytes` | More than 128 KiB arrived before authentication completed. |
| `connection_capacity` | The listener has 128 connections or is shutting down. |
| `channel_capacity` / `session_capacity` | The 16-channel connection or 256-channel listener budget is full, or shutdown is underway. |
| `authorization_revoked` | A new channel no longer has an authorized identity. |
| `unsupported_channel` | The requested channel type is unsupported. |
| `protocol_error` | SSH parsing/transport failed; intentionally omits attacker-controlled details. |

Diagnostics are best effort: at most eight records per 60-second window per
listener and eight pending writes. A blocked stderr writer does not block the SSH
event loop or grow an unbounded queue. Suppressed totals appear on the next admitted
record, not a timer. Under sustained abuse individual reasons may be suppressed;
absence of a record is not proof a connection was accepted. Configure retention in
your service manager. These records are not a durable security audit trail.

No authentication/admission limits are relaxed by these diagnostics.
