# Provider acceptance and account access

Native wire adapters, fixture tests and authenticated provider acceptance are separate checks. A passing fixture suite does not establish account eligibility, model access, available credits or current service behavior.

## Opt-in native transport check

Use an existing Kiln state directory with a configured provider profile and Vault grant:

```sh
python3 scripts/provider-live-acceptance.py --state /absolute/path/to/state --profile work
```

This is an explicit live-inference command and can consume provider credits. `--profile default` reads `ai.json`; a named profile reads `ai-profiles/NAME.json`. Credential values are resolved inside the Swift test process using the profile's existing Vault scope. Keys never appear in command arguments, output or test prompts. The command does not change the active runtime profile or operate on installed applications.

The check performs three bounded requests through Kiln's actual provider router:

1. Request one registered, read-only `fixture_status` call with no arguments.
2. Supply a synthetic healthy result and require a streamed final answer acknowledging it.
3. Start another response and cancel after the first answer delta.

Only provider identifiers, pass/fail state and answer-frame counts are emitted. No provider answer, request body, credential or endpoint is printed. Existing per-request output/time limits apply. A completed tool round proves transport and history mapping for that account/model; it is not a general agent-quality benchmark or a multi-agent load test. A single answer frame is recorded honestly and does not prove token-by-token delivery.

Without the opt-in environment set by the runner, `providerLiveAcceptance` performs no network calls. The harness requires a Swift toolchain because it tests the source adapter directly; ordinary Kiln users can run released binaries without this development check.

## Account and subscription boundaries

Reviewed against provider documentation on 2026-10-13:

- **Claude:** Native Messages access uses a Console API key. Claude's official support page documents monthly API credits for eligible Max and Team plans, claimed into a linked Console organization. This is an account credit entitlement, not a generic permission to extract subscription session tokens. Users claim credits themselves and store that organization's API key in Kiln Vault. [Monthly API credits](https://support.claude.com/en/articles/17154008-monthly-api-credits-for-max-and-team-plans).
- **Grok:** The official CLI supports `grok login`, including `--device-auth` for headless environments. CLI login and native `api.x.ai` API-key authentication are different paths. A successful login must not be presented as verified inference or a guarantee of subscription entitlement. Kiln must use a documented, user-completed login flow and leave token handling to the supported integration. [CLI reference](https://docs.x.ai/build/cli/reference).
- **DeepSeek:** The documented native API requires an API key. No subscription sign-in path for Kiln was verified in the reviewed documentation. [First API call](https://api-docs.deepseek.com/).

The integration does not read browser cookies, export desktop session tokens or imitate a provider's private subscription API. API keys authorize the account that issued them; they do not automatically inherit a similarly named consumer subscription.

## Current acceptance limits

The provider fixture suite verifies request shapes, streamed parsing, failure handling and tool-result mapping. Authenticated acceptance requires operator-provided profiles and credentials. During the 2026-10-13 discovery pass, the previously recorded local demo and Ollama state directories were absent and no matching provider API credential environment variables were present locally. The authorized Fleet sandbox account contained an Erebine provider configuration; its credential was used only through a disposable encrypted Vault for the acceptance run. Other hosted providers require operator-supplied account configuration. Missing configuration is not a provider outage.

Observed on 2026-10-13:

| Provider | Authenticated native acceptance |
| --- | --- |
| Erebine | Passed: one read-only fixture tool round, four answer frames, cancellation after actual streamed content |
| OpenAI API | Not run: no configured API credential available |
| Claude API | Not run: no configured API credential available |
| Grok API | Not run: no configured API credential available |
| DeepSeek API | Not run: no configured API credential available |
| ChatGPT account | Implemented OAuth/PKCE; authenticated sign-in and inference pending user consent |
| Grok CLI account | Implemented device sign-in; authenticated sign-in and inference pending user consent |
| Local Ollama | Passed with cached `qwen3:0.6b`: read-only fixture tool round, eight answer frames, cancellation after actual streamed content |

Erebine evidence: `KILN_PROVIDER_ACCEPTANCE provider=erebine tool_round=pass answer_frames=4 cancellation=pass`. Local Ollama evidence: `KILN_PROVIDER_ACCEPTANCE provider=ollama tool_round=pass answer_frames=8 cancellation=pass`; no model download or daemon change was needed. The disposable state and master key were removed afterward. Subscription sign-in requires its own account flow and is deliberately excluded from this API-key acceptance runner.

Do not mark an unrun provider check as passed. Record a redacted acceptance line for each configured account/model tested; keep fixture-only and live-verified status distinct in release notes.

## Fresh acceptance on 2026-10-23

The preview-acceptance branch passed the native read-only tool/result round,
streamed answer and cancellation checks against both Erebine and ChatGPT:

```text
KILN_PROVIDER_ACCEPTANCE provider=erebine tool_round=pass answer_frames=2 cancellation=pass
KILN_PROVIDER_ACCEPTANCE provider=chatgpt tool_round=pass answer_frames=6 cancellation=pass
```

Erebine configuration came from the operator-designated Fleet OpenCode sandbox
account. Its credential was piped directly into a disposable encrypted Kiln Vault,
without printing the value or placing it on argv. This run's two reported answer
frames do not imply token-by-token output for tool-enabled Erebine planning.

ChatGPT used user-completed official consent and its live model catalog. Account
restore after a runtime restart and explicit grant renewal succeeded; the complete
native acceptance check passed again after renewal. Required synthetic tool
selection makes the transport assertion deterministic. No API-key fallback was
used. Live sign-out/revocation remains untested so the requested connection can
remain available. Grok accounts and the other API-key routes retain their previous
unverified live-acceptance boundaries.

See [current preview acceptance](preview-acceptance.md) for local core suites,
compiler differences and outstanding platform/client release gates.
