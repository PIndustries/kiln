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
This path does not promise subscription access.

The current launcher supports macOS with `/usr/bin/sandbox-exec`. It creates an
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

Linux launch is unavailable until an OS isolation launcher is implemented and
verified. No unsandboxed fallback exists. CLI versions requiring a background
leader process or additional host access fail closed. Neither a successful help
probe nor fixture tests prove an authenticated model request works.

Validation includes byte-fragmented UTF-8 streaming, tool-event rejection, missing
exit receipts, cancellation, deadlines and output limits. Set
`KILN_TEST_GROK_SANDBOX=1` for the real macOS filesystem-isolation test. The installed
CLI was launched with `--help` inside the restricted profile. A real headless
request with an invalid fixture key and the CLI-listed `grok-4.6` model reached
authentication rejection. No account credential was used. Authenticated inference
with a CLI-supported model remains an operator acceptance check.

References: [headless protocol](https://docs.x.ai/build/cli/headless-scripting),
[CLI flags](https://docs.x.ai/build/cli/reference),
[permission boundaries](https://docs.x.ai/build/features/permissions),
[sandbox limitations](https://docs.x.ai/build/features/sandbox).
