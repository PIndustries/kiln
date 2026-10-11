# Kiln AI — native provider integration

Kiln AI is a Swift library and SSH chat interface using Foundation HTTP directly against Erebine's chat-completions API or the native Ollama chat API. OpenCode is not invoked or required at runtime. The module implements conversation history, a bounded tool loop, local operation proposals, Vault-backed credentials and versioned operator knowledge.

## Chat

In Kiln's SSH dashboard, click **7 AI Chat** (or **7 AI** on smaller terminals), or press **7**. You can also open the backtick drawer and type:

```text
ai
```

AI opens a dedicated conversation screen. Ask naturally, for example:

- "Which modules are running? Check their health."
- "Report host memory and CPU."
- "Explain how rollback works in Kiln."
- "Propose restarting storefront/rest."

Chat uses the available terminal width with a small two-column inset, resizing its transcript, dividers, and composer with the viewport. Incoming and completed answers preserve line breaks and render common Markdown markers as readable terminal text. Page Up/Down scrolls output. `/exit` returns to commands, `/reset` clears that session's context and proposals. Answers stream through native SSE (Erebine) or NDJSON (Ollama) as they arrive, alongside a compact tool-call count. Provider reasoning is shown transiently only when the provider sends it; Kiln does not fabricate a thinking trace. Ctrl-C cancels a foreground response or stops watching a task. Ctrl-S freezes the display and disables mouse capture for native terminal selection/copy; press Ctrl-S again to resume.

The chat sidebar lists session-owned pending approvals and administrator-visible background tasks, refreshed every second. Click a proposal to review the exact operation, then click **Approve** or **Deny**; the same server-side authorization, expiry, single-use and generation checks apply as `/approve` and `/deny`. Click a task to inspect its current record. Type a request into the composer and click **+ New task from message** to run it as a background investigation. With an empty composer, this button prepares `/task` input.

**Tab** switches focus between the composer and sidebar; arrows select an item and **Enter** opens it. In the approval review, Tab/arrows choose a button, Enter activates it, and Esc returns. On terminals narrower than 110 columns, Tab opens a full-width task/approval panel. Background task state remains visible across SSH sessions for administrators; proposals remain private to the originating session and expire after five minutes.

Read-only tools run automatically within the signed-in identity's permissions. `module_resources` reports scoped module limits and enforcement; `cluster_status` reports peer inventory for administrators. Peer mutations are currently available through administrator CLI commands, not AI tools. A requested change produces an exact `app start`, `stop`, `restart` or `rollback` proposal. It does not execute based on model prose. Review the module/action, then use `/approve ID` or `/deny ID`. Approvals belong to the originating SSH session, expire after five minutes, and can be consumed only once. If the module's process state, PID or version changed since the proposal, execution is refused. A consumed proposal is not automatically retried after failure.

Other command interfaces support:

```text
ai ask "Report the current system state"
ai status
ai reset
ai approve <id>
ai deny <id>
```

Independent SSH exec connections have separate conversation identities; approve in the same interactive session that produced the proposal. The local console has its own conversation.

## Configure Erebine

Initialize Vault as described in [Vault setup](vault.md). Store the Erebine inference API key using hidden entry, then configure its reference:

```text
vault put erebine-api
vault grant kiln/ai erebine-api
ai configure https://api.erebine.ai/PROJECT/WORKSPACE/_direct/v1 MODEL_ID erebine-api
ai status
```

Use the base URL and model ID supplied by your Erebine endpoint or OpenCode provider configuration. A direct-routing endpoint's model ID must match its model catalog. Erebine accepts only HTTPS; credential-bearing URLs and redirects are rejected. `ai.json` stores the base URL, model and secret reference, never the API key. Each turn resolves the named grant from Vault, so rotating the key applies to the next turn without a runtime restart.

Provision an Erebine API credential into the encrypted Vault using hidden terminal entry or redirected stdin. Provider configuration and credentials are local operator state and must never be included in a distributable package.

## Named profiles and local Ollama

Provider support in this release is explicit: Erebine and local Ollama only. ChatGPT subscription sign-in, OpenAI adapters and Claude adapters are not implemented by this slice. There is no automatic provider fallback.

```text
ai profile add local ollama http://127.0.0.1:11434 qwen3:0.6b
ai profile use local --new-context
ai status
ai ask Report the current system state
```

Install and run Ollama separately and choose an already-installed tool-capable model. Kiln never installs a daemon, pulls a model or registers tools from model output. Ollama uses `/api/chat`, incremental NDJSON content/thinking events, object-valued function arguments and `tool_name` results. Only a literal `127.0.0.1` or `::1` HTTP origin is accepted; no API key, redirects, hostname resolution or remote Ollama endpoint is enabled. Loopback transport does not establish where a separately configured Ollama daemon runs inference: choose a local model and audit that daemon's cloud/proxy configuration independently. Requests specify an 8192-token context, a 4096-token output limit and one-minute model keep-alive; these are inference settings, not hard memory quotas on the separately managed daemon. Model capability and output quality vary; unsupported tools fail rather than gaining another execution path.

Named hosted profiles use their own Vault grants:

```text
vault put work-api
vault grant kiln/ai-work work-api
ai profile add work erebine https://api.erebine.ai/PROJECT/WORKSPACE/_direct/v1 MODEL_ID work-api
ai profile list
ai profile use work --new-context
```

There are at most 16 named profile files, each containing an endpoint, provider, model and optional Vault reference, never credential values. Adding or replacing a saved profile does not activate it. Selecting one requires the explicit `--new-context` flag and clears pending proposals and conversation history. Each turn and its presentation retain one immutable configuration snapshot. Queued/running tasks retain their original provider configuration even if the active selection changes; they resolve that profile's Vault grant when execution begins. Tasks interrupted by process restart still do not replay.

Profiles encode `schemaVersion: 1`; unknown future versions are rejected. Existing three-field `ai.json` files without a version decode as the default Erebine profile; `ai configure URL MODEL SECRET` remains supported and selects that default using `kiln/ai`. Other names use `kiln/ai-NAME`. Provider, endpoint, model, credential reference, profile and context generation all participate in conversation isolation. Switching back to a prior profile also creates a fresh context. Rotating a value behind the **same** Vault reference retains context; if that changes accounts rather than rotating the same account's key, explicitly reselect with `--new-context` first.

Tests exercise legacy decoding, local endpoint boundaries, streaming UTF-8/NDJSON, malformed/truncated responses, cancellation, tool-result mapping, admin-only selection, conversation isolation and queued-task profile binding without external calls. The opt-in `KILN_TEST_OLLAMA_MODEL=qwen3:0.6b swift test --filter ollamaLiveLocalStreamingAndToolRound` uses an installed local model and disposable status data; it does not pull a model or use paid APIs. A live smoke check verifies a normalized tool round and multiple final-answer frames, not general model reliability.

Implementation references: [Ollama chat API](https://docs.ollama.com/api/chat), [tool calling](https://docs.ollama.com/capabilities/tool-calling), and [Qwen3 0.6b model](https://ollama.com/library/qwen3:0.6b).

## How it understands Kiln

The assistant receives three distinct layers:

1. Built-in, versioned Kiln knowledge describing implemented lifecycle, ingress, SSH, session, Vault and module behavior, with planned capabilities clearly identified.
2. Current runtime release and installed module state on every turn; live tool calls fetch metrics, health and release information.
3. An optional operator knowledge pack with application-specific explanations and runbooks.

Example knowledge pack:

```json
{
  "version": "26.10.07.3",
  "notes": "The inventory/api module serves inventory queries. Its owner is the inventory team. Use its configured health check before proposing a restart."
}
```

Install it inside Kiln:

```text
ai knowledge install /absolute/path/knowledge.json
ai status
```

The next turn uses the new pack, without restarting. The pack replaces the previous operator pack; it is not an append operation. It is limited to 24 KiB of notes. Do not put credentials in it. Existing conversation context remains until `/reset` or expiration.

Knowledge is reference data, not executable policy. A pack cannot register tools, grant secrets, change the approval requirement or run commands. New platform capabilities require adding typed Swift tool definitions/handlers and tests, then releasing the updated runtime. This version does not automatically read application source code or discover arbitrary third-party tool servers.

## Tool boundary

Available reads: runtime status, module list, host metrics, per-module health, resource limits and enforcement, active/previous releases, ingress address and task inventory. Administrators can also inspect adopted peer-node inventory with `cluster_status`; this does not execute remote operations.

Available proposed changes: start, stop, restart and rollback of an already-installed module. The supervisor checks the module generation before execution. No model-produced string is passed to a host shell or general-purpose command dispatcher.

Not exposed: Vault values or grant management, application logs, arbitrary files, server execution, network browsing, installation/deployment from arbitrary paths, and provider account administration. Terminal output is sanitized by the existing TUI renderer.

The model can still make mistakes or write misleading prose. The locally generated proposal and execution result are the authoritative action record. Permission enforcement lives in Swift rather than in the system prompt.

## Data, cost and operational boundaries

Prompts, the built-in/operator knowledge, runtime context and selected tool results are sent to the selected provider endpoint. Erebine API credentials are used only in the authorization header. Requests set `store: false`; this does not replace the provider's retention policy or establish zero-data-retention by itself. Inference may consume account credits.

Conversations and pending proposals stay in runtime memory. Up to 32 idle conversations are retained, with a one-hour idle expiry; context is reset when its configured size limit is reached. At most 48 conversations can perform inference concurrently. Background concurrency defaults to four and is operator-configurable from 1–48. Each turn has up to eight tool-capable model calls followed by one summarization call with tools disabled, six tool calls per model response, and 4096 output tokens per model request. Identical tools are cached within the turn; an exhausted budget returns collected results instead of discarding them. Requests have bounded timeouts. Streaming requests rejected with HTTP 429 and the documented `capacity_exceeded` or `rate_limit_exceeded` code may retry twice when a valid `Retry-After` is at most 60 seconds. Chat shows a cancellable countdown. Quota failures, unknown errors, timeouts and interrupted streams are not retried; completed tool operations are never replayed by this policy. Error bodies are bounded and only reviewed error categories reach the terminal. A timeout may still consume provider credits. Disconnecting cancels foreground inference and task watchers; background tasks continue until finished or explicitly cancelled.

This is an integrated runtime module, not yet an independently hot-replaceable AI service. The framework target uses Foundation/FoundationNetworking and supports headless design; runtime and live-provider validation were performed on macOS. Linux compilation and AI policy tests now pass; live Erebine calls were verified on macOS.

## Verification and references

`swift test` includes deterministic policy tests using a test transport: unavailable tools, credential exclusion from messages, read tools, knowledge updates, session-bound single-use proposals and native chat commands. These tests do not contact Erebine.

The opt-in scripts `ai-live-integration.py` and `ai-terminal-integration.py` use real Erebine inference and disposable Swift workers, with an operator-supplied configured Vault. They can consume API credits. They verify live reports, tool calls, proposal-before-execution, explicit approval, rejected replay, knowledge reload and the real SSH chat view.

API implementation references: [Erebine Chat Completions](https://erebine.ai/docs/api-reference), [Tool Calling](https://erebine.ai/docs/tool-calling), and [OpenCode provider configuration](https://erebine.ai/docs/opencode).

Approved operations now persist private outcome receipts before execution; use `ai operations` to inspect them. See [supervision and operation receipts](supervision.md) for interruption semantics. Pending approvals are still in memory and session-bound.

## Background tasks

Ask the chat to create a background investigation, or use:

```text
/task Inspect all modules and report unhealthy services
/tasks
/watch TASK-ID
/cancel TASK-ID
```

The command drawer also accepts `ai task new <request>`, `ai task list`, `ai task show <id>`, `ai task watch <id>`, `ai task cancel <id>`, `ai task remove <id>` and `ai concurrency [1-48]`. Lowering concurrency affects admission of subsequent jobs; it does not terminate active jobs. The cap is Kiln's scheduling limit, not a claim about provider quotas or a 48-agent performance benchmark.

Task workers may inspect status, modules, host metrics, health, resource limits and enforcement, releases and task inventory within the initiating identity's permissions. Administrator tasks may also inspect adopted peer-node inventory. They cannot mutate the runtime, propose operations, create more tasks, run shell commands, or change their own concurrency. Interactive chat retains the existing approval flow for mutations. These are bounded investigation tasks, not general coding agents or a workflow DAG engine.

Task IDs, requests, status and final results persist in private `ai-tasks.json` (0600). Do not place credentials in prompts; task records are not Vault-encrypted. Provider reasoning is transient and excluded from task records. History is capped at 200 tasks; remove finished entries when full. Interrupted/queued work is marked interrupted after a runtime restart and is never automatically replayed. A viewer disconnect does not stop the task. Results can be inspected from a new SSH connection using the same configured administrator identity.

The SSE parser handles UTF-8 and tool arguments split across network packets, rejects oversized/truncated streams, and executes tools only after a complete response. Incoming output repainting is coalesced at 50 ms; an independent 100 ms activity animation remains visible while waiting for provider output. Only changed chat rows are transmitted. No fake token delay or fabricated progress is added; text selection freezes repainting. Streaming follows [Erebine's chat API](https://erebine.ai/docs/api-reference) and [SSE format](https://erebine.ai/docs/streaming). These pages differ on reasoning-channel availability, so the implementation accepts optional `reasoning_content`/`reasoning` fields and reports only what the provider sends.


For provider timing diagnostics, set `KILN_LIVE_STATE` to an existing configured state directory and run `swift test --filter optionalLiveProviderStreamTiming`. This opt-in test consumes inference credits and reports only chunk counts, byte counts and arrival times, never credentials or response contents. Provider latency before the first answer is distinct from terminal rendering latency. The SSH UI test requires at least three distinct partial answer frames before completion and an animated waiting state.

Erebine currently emits tool-enabled answers as a single content chunk in our measurements. Kiln therefore uses a bounded tool phase followed by a separate tool-free presentation request. Only the presentation answer is displayed as live text; provider reasoning and activity remain visible during planning. This adds an inference request and provider latency/cost. The presentation receives verified tool results, cannot execute operations, and falls back to the completed draft if it fails. No operation is replayed during fallback.

## Provider transport counters

Administrators can run `ai metrics` without sending an inference request. Counters are
in-memory and reset when the process restarts. They aggregate the assistant's native
streaming attempts across sessions, with fixed categories for completion, capacity,
rate limits, quota, authentication, other rejection, timeout, cancellation, transport
failure and invalid response. Retried attempts count separately. Cancellation while
waiting to retry has its own counter and does not invent another HTTP attempt.
Elapsed totals and maxima measure attempts, excluding retry waits; no percentile or
billing estimate is inferred. Counters saturate rather than wrap.

There are no prompt, credential, model, account, endpoint or provider-error labels.
Injected test completions and standalone nonstreaming clients are outside these
assistant counters. An HTTP/stream completion does not prove a tool operation ran:
`ai operations` remains the separate record of approved operation outcomes. Task
states remain available in `ai task list` and the task sidebar.
