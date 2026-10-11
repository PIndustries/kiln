# Kiln Vault — single-node credentials

Vault is a headless server component implemented in Swift using Swift Crypto. It does not use Keychain, a GUI login, or a cloud account. Vault encryption, tamper rejection and per-module grants are tested on macOS and Linux x86_64. Existing bastion SSH keys remain in their separate Keychain-backed store on macOS.

The `KilnVault` target encrypts secret values and grants together using AES-256-GCM with authenticated encryption. A randomly generated 32-byte master key is held in an explicit file **outside the Kiln state directory**. This is protection for stored data and state backups, not a sandbox against programs running as Kiln's OS user.

## Initialize on the server

Create a protected key directory owned by the same OS user that runs Kiln. Example for an operator-provisioned Linux service account:

```sh
# Paths must exist and be writable by the Kiln service account.
kiln vault init --state /var/lib/kiln --key-file /etc/kiln/keys/vault.key
```

Initialization creates a new master key with mode `0600` and refuses to overwrite an existing key or Vault. The parent key directory should have mode `0700`. No key is printed. Runtime access requires the key file to be a regular file, owned by the service user, with mode `0600`. The path is recorded in `vault-config.json`; values and grants are in `vault.enc`.

The service opens the key without an interactive unlock step, so unattended startup works when the file is available. Protect that file independently; possession of the encrypted store plus its master key permits decryption. Keep a separate protected backup of the key. Losing it makes the secrets unrecoverable. For restore, preserve the configuration, encrypted store and key; restore the key at its configured path with the required ownership and permissions. There is no master-key rotation or automated recovery workflow yet.

## Backup and restore rehearsal

Take backups while Kiln is stopped and local Vault administration is paused. Keep `vault-config.json` and `vault.enc` as a matching pair; their configuration identity is part of authenticated decryption. Store the master key in a separate protected backup location with independent access controls. Do not include it in a release artifact or the ordinary state archive. A Vault-only backup does not include application data, manifests, SSH identities or other runtime state; back those up separately as required.

For recovery:

1. Stop Kiln and pause all local Vault writers. Preserve the damaged files for private investigation; do not run `vault init` over an existing store.
2. Restore the matching configuration and encrypted store into the state directory. Restore the original master key at the absolute path recorded in the configuration. Recreating that path on the recovery host avoids changing the configuration; automatic path migration is not provided.
3. Restore ownership to the Kiln service user. Use protected directories (mode `0700`) and regular files with mode `0600` for the configuration, ciphertext and key. Do not substitute symlinks.
4. Verify Vault access under the service identity, then verify an explicitly granted module can start and an ungranted or revoked module is denied. Use disposable credentials and digest-only checks for rehearsals; do not print a recovered value.
5. Rotate any exposed upstream credential and update its Vault value through hidden entry or stdin. Restart consumers to receive it. Confirm the old credential is rejected by its issuer; restoring a backup or replacing a Vault value does not revoke the old upstream credential.

A missing key or a different valid 32-byte key must fail closed without changing ciphertext. Only a matching configuration, store and master key can restore access. Backups preserve the grants and revocations present when taken, so review policy before starting restored consumers: an older backup can predate a later revocation. A restored older credential may also have been revoked at its provider. No automated master-key rotation is implied by this procedure.

The disposable `vaultBackupRestoresSeparateKeyAndPreservesGrantDenials` test copies state and key separately, deletes the originals, proves missing/wrong-key denial, restores the correct key, checks grants/revocation and confirms a replacement value after reopen. Assertions compare booleans rather than rendering recovered values. This is a Vault storage recovery test, not proof of full-node recovery, provider acceptance, or replacement delivery to an already-running process.

## Store credentials through SSH

Connect to Kiln's dashboard, open the backtick command drawer, and enter:

```text
vault put cloudflare-production
```

A separate hidden-entry screen opens. Type or paste the value; Enter saves. Escape/Ctrl-C cancels, Backspace edits, and Ctrl-U clears. Values never enter the drawer's command history or transcript. Entry is limited to 16 KiB, one line. Empty values are rejected. Repeating `vault put` replaces the value while preserving grants.

Never append a secret value to the command. There is deliberately no reveal command. Plain SSH exec and the local console do not accept inline secret values.

For headless provisioning, import from stdin:

```sh
kiln vault put cloudflare-production --state /var/lib/kiln < /run/secrets/cloudflare-token
```

This accepts UTF-8 values up to 16 KiB, including multiline values, and removes one final line ending. The input file is your responsibility; protect and remove it according to your provisioning system. Secret values are not supplied in command arguments.

## Grant a module only what it needs

Inside Kiln:

```text
vault list
vault grant storefront/api cloudflare-production
vault grants storefront/api
```

Add a named binding to the module's JSON manifest:

```json
"secrets": {
  "CLOUDFLARE_API_TOKEN": "cloudflare-production"
}
```

A grant is attached to the exact `application/module` identity. A manifest cannot grant itself access. Before **every** process launch, including deployment, rollback and restore, Kiln resolves the manifest's bindings against the stored grants. If any binding is missing or denied, the process does not start. Granted secrets not requested in the manifest are not delivered. A failed deployment leaves the active release unchanged.

The worker receives only the resolved values in its environment:

```swift
let token = ProcessInfo.processInfo.environment["CLOUDFLARE_API_TOKEN"]
```

The supervisor supplies the identity; there is no module-facing API accepting a caller-supplied module name. Reserved environment names such as `PATH`, `KILN_*`, `DYLD_*` and `LD_*` cannot be used as secret bindings.

## Rotation, revocation and deletion

```text
vault put cloudflare-production
vault revoke storefront/api cloudflare-production
vault delete cloudflare-production
```

Values are delivered at startup. Rotation applies on the next start/deployment. Revocation blocks future delivery; it cannot erase values already received by a running process. Stop that process and rotate the upstream credential if immediate invalidation is required. A restart with a still-requested but revoked secret fails closed. Deletion requires revoking all grants first.

## Boundaries

- Only administrator identities can manage Vault, including hidden TUI entry. Named roles, live revocation and bounded metadata audits are described in [identity permissions](identities.md).
- Grants control supervisor delivery between trusted modules. Same-UID processes and host administrators can access the master key or process data; OS isolation is still required for hostile modules.
- A receiving module can print or transmit a secret. Kiln's Vault commands do not log values, but application logs are not automatically redacted.
- This is single-node storage, with a file lock coordinating local processes. No cluster replication, leases, dynamic credentials, provider integrations or HSM integration is implemented.
- Missing keys, invalid permissions and ciphertext authentication failures stop Vault operations. No plaintext fallback exists.
- An unavailable Vault prevents modules requiring secrets from starting. Other modules do not need an initialized Vault.

## Verification

`swift test` covers encrypted persistence, explicit grants, denial, rotation, revocation, tampering, missing keys and module startup enforcement. `scripts/vault-integration.py` exercises hidden entry and cancellation using real OpenSSH, checks a launched worker's received credential by digest, and verifies that raw values are absent from captured SSH output and runtime state/log files. Test credentials are disposable. The SSH fixture also checks a fresh observation from the running worker after rotation still uses its original value, then requires a new worker PID and replacement digest after restart. Other-module and revoked-grant starts are denied without writing a delivery proof.

`vaultCanariesStayOutOfAuditsTelemetryAndAIContext` combines a real disposable Vault, command auditing, host metrics and an injected offline AI completion. It checks that provider credential rotation reaches the next AI turn, revocation prevents another completion, an unregistered Vault-read tool is denied, and all three random credential values remain absent from captured model messages, command output and audit records. It does not call Erebine or claim that a credential is accepted by an external provider.

Both macOS and Linux CI run the hidden-entry/rotation fixture with a test-only virtual environment and hash-pinned dependencies from `scripts/terminal-test-requirements.txt`. To repeat locally after building:

```sh
python3 -m venv /tmp/kiln-terminal-tests
/tmp/kiln-terminal-tests/bin/python -m pip install --require-hashes --only-binary=:all: -r scripts/terminal-test-requirements.txt
/tmp/kiln-terminal-tests/bin/python scripts/vault-integration.py
```

State replacement flushes encrypted contents and configuration before reporting success. If initialization cannot confirm its final write, Kiln retains the newly created key and state files instead of deleting potentially committed data. Inspect the existing files or restore a matching backup before attempting initialization again. The master-key parent must be owned by the runtime user and must not allow group/other writes.

Vault reads validate ownership, mode 0600 and regular-file type on the same open descriptor used for reading; symlinks are rejected. Configuration is bounded to 16 KiB and the encrypted store to 16 MiB. These checks prevent accidental exposure through loose file permissions and unbounded allocation from a damaged state file. They do not make the Vault secure against arbitrary code already running as Kiln's OS user.
