# Grok headless worker

Grok's HTTP API and its installed CLI are separate backends. The headless worker
uses the CLI's ACP update stream; it is not a replacement for the Kiln tool broker.

An administrator can run:

```
ai headless ask /absolute/path/to/grok MODEL VAULT_SECRET "Your request"
```

The referenced Vault secret must be granted to `kiln/ai-grok-cli`. Authentication
uses an explicit API credential in the child environment. Existing desktop login,
user configuration, SSH keys, hooks and project configuration are not imported.
For account sign-in, Kiln uses the CLI's official device flow in a new isolated
home. It does not import a desktop login. A successful sign-in enables only the
entitlements the provider grants to that account; it is not a claim that every
subscription includes CLI access.

```
ai login grok /absolute/path/to/grok
ai login grok-status ACCOUNT_ID
ai headless account ACCOUNT_ID MODEL "Your request"
```

Only the initiating identity can inspect the verification code or use the account.
Kiln retains the CLI's opaque `.grok/auth.json` in encrypted Vault storage (12 KiB
maximum), not in account metadata. Each call restores it into a temporary 0700
home with a 0600 auth file, then saves CLI-managed refresh changes back to Vault.
No token fields are parsed. Sign-out removes the local Vault credential; provider
session revocation is available separately in the provider account. Login attempts
expire after ten minutes; unfinished sign-in cannot resume after a restart.
Cancel its pending record and start again. Account storage uses an interprocess
lease; concurrent account operations receive a busy response while a request
refreshes its credential. Use `ai login grok-cancel ACCOUNT_ID` to cancel login
and `ai logout grok ACCOUNT_ID` to remove an account.

The macOS launcher uses `/usr/bin/sandbox-exec`. It creates an
empty temporary home/workspace, strips inherited environment variables, restricts
file contents to system runtime files, the selected executable and that workspace,
and permits writes only inside the temporary workspace. Filesystem metadata is
readable for runtime loading. Process forks are denied. Outbound network access is
permitted for inference; this is not an endpoint-specific network filter.

Grok tools, subagents and web search are disabled in the request. The vendor
sandbox flag is off because Kiln applies its own OS profile before executing the
CLI; nesting the vendor profile failed on this machine during Docker socket
resolution. Unexpected tool
events fail the worker. Text is never interpreted as a Kiln command. Execution has
a deadline, cancellation, bounded streaming output and an explicit exit receipt;
raw diagnostic output is withheld. The temporary workspace is removed on exit.

Linux uses `/usr/bin/bwrap` with working unprivileged user namespaces. It creates
fresh mount, PID, IPC and UTS namespaces, drops capabilities, mounts only the
selected executable, runtime libraries, trust roots and DNS configuration read-only,
and exposes a writable temporary workspace. The network namespace is shared for
inference. It does not mount the host home, repository, SSH directory or host root.
`--die-with-parent` and the PID namespace terminate descendants when the supervisor
is killed. Missing bubblewrap or a host policy that forbids namespaces causes a
closed failure. No unsandboxed fallback exists. CLI versions requiring a background
leader process or additional host access fail closed. Neither a successful help
probe nor fixture tests prove an authenticated model request works.

Validation includes byte-fragmented UTF-8 streaming, tool-event rejection, missing
exit receipts, cancellation, deadlines and output limits. Set
`KILN_TEST_GROK_SANDBOX=1` for real filesystem-isolation and account-lifecycle tests;
Linux additionally checks cancellation of a forking worker. The installed
CLI was launched with `--help` inside the restricted profile. A real headless
request with an invalid fixture key and the CLI-listed `grok-4.6` model reached
authentication rejection. No account credential was used. Authenticated inference
with a CLI-supported model remains an operator acceptance check.

On Linux, the same bubblewrap arguments were verified on Fleet: a scratch file was
readable, an outside marker was absent, and a forked child's heartbeat stopped
after supervisor termination. The official CLI 1.0.52 binary downloaded over HTTPS
also listed its models under isolation. Its recorded SHA-256 was
`1668414b047e1050a96d25fe17dfc3efe63190fbf66d8cc1c3de8633caf50d11`;
this is a recorded digest, not an independently published vendor checksum.

References: [headless protocol](https://docs.x.ai/build/cli/headless-scripting),
[CLI flags](https://docs.x.ai/build/cli/reference),
[permission boundaries](https://docs.x.ai/build/features/permissions),
[sandbox limitations](https://docs.x.ai/build/features/sandbox).
