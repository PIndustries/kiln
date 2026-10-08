# Named SSH identities and permissions

Kiln authenticates standard OpenSSH public keys against a local identity policy. On the first SSH startup, `--user` (default `admin`) and `--authorized-keys` bootstrap an administrator. Subsequent startups use `identities.json`; editing the bootstrap key file does not re-enable revoked identities. `identities.initialized` prevents a missing policy from silently reimporting old credentials. Back up both files with runtime state. A missing/corrupt policy fails closed; recover it through trusted local OS administration.

```
identity add alice operator /path/alice.pub storefront/rest,storefront/websocket
identity add observer viewer /path/observer.pub storefront/rest
identity list
identity set alice viewer storefront/rest
identity revoke alice
```

Users connect as their identity name: `ssh -i alice-key -p 2222 alice@host`. Identity add replaces that user's key; role changes preserve it. Keys are parsed as OpenSSH public keys. The last enabled administrator cannot be revoked or demoted. This validates key syntax, not proof that someone retains its private key; install and test a backup administrator before rotating your sole usable key.

| Role | Authority |
| --- | --- |
| Viewer | Status, host metrics, visible module state, health, logs, releases/resources, and interactive AI read tools |
| Operator | Viewer plus start, stop, restart and rollback of permitted modules; AI changes still require an explicit approval |
| Admin | All commands, installation/deployment, identity policy, Vault, bastion terminals/forwarding, AI configuration/tasks and cluster adoption/operations |

An omitted module scope grants all modules; explicit scopes match exact `application/module` names. Administrator scopes do not reduce administrator authority. Unknown commands fail closed. Console and local OS access remain administrative and are not restricted by SSH roles. These controls are not an OS sandbox against a process that can modify Kiln's state files.

SSH sessions retain identity rather than a role snapshot. Every command, AI tool read and approved mutation resolves the current policy. Revocation prevents new commands and connections; interactive refresh closes revoked sessions. Demoting an administrator closes its active remote terminal and forwarding access on the next input/permission check (approximately one second for forwarding). Already-authorized operations may finish. AI task history is currently administrator-only; there is no cross-user task sharing. AI conversations are session-bound; prompts do not become authorization.

Administrative changes require an audit intent before dispatch. Per-command audit records contain a request ID, principal, action, safe target when applicable, and returned/failed/denied outcome. They exclude AI prompts, command bodies and secret values. A completion-audit failure reports an uncertain recorded outcome and asks for state inspection; it does not claim an already executed operation was undone. Hidden Vault entry uses the same administrator check and audit path. Audit files and identity policy are private mode 0600. There is no external tamper-proof audit sink or automatic archive export yet.

Validation: `swift test --filter 'identity|auditExcludes'` and `python3 scripts/identity-integration.py` use isolated state and generated test keys.

Audit capacity is bounded: mutation evidence stops at 4,096 files or 8 MB; it is never automatically discarded to permit another change. Archive the `audit/*.json` files outside runtime state through trusted local administration before removing archived files. Preserve unmatched authorized intents and investigate them before retrying operations. Read-only commands do not write audit files and remain usable when capacity is exhausted. Denied attempts use a separate rolling directory, `audit/denied`, capped at 256 records so an unprivileged client cannot exhaust the mutation journal. Direct hidden-secret entry and AI-created background tasks require audit intents too. A mutation whose completion record hits capacity reports an uncertain audit outcome; its operation may already have happened.

After the first successful bootstrap, the saved identity policy is authoritative. The original `--authorized-keys` file may be removed; keep the same startup argument for compatibility. A missing or invalid initialized policy fails closed instead of importing that file again.
