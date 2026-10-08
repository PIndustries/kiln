# Kiln AI — native Erebine integration

Kiln AI is a Swift library and SSH chat interface using Foundation HTTP directly against Erebine's chat-completions API. OpenCode is not invoked or required at runtime. The module implements conversation history, a bounded tool loop, local operation proposals, Vault-backed credentials and versioned operator knowledge.

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

Responses use a centered reading column of up to 96 characters, adapting to smaller terminals. Incoming and completed answers preserve line breaks and render common Markdown markers as readable terminal text. Page Up/Down scrolls output. `/exit` returns to commands, `/reset` clears that session's context and proposals. Answers now stream through native SSE as they arrive, alongside a compact tool-call count. Provider reasoning is shown transiently only when Erebine sends it; Kiln does not fabricate a thinking trace. Ctrl-C cancels a foreground response or stops watching a task. Ctrl-S freezes the display and disables mouse capture for native terminal selection/copy; press Ctrl-S again to resume.

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

Use the base URL and model ID supplied by your Erebine endpoint or OpenCode provider configuration. A direct-routing endpoint's model ID must match its model catalog. Only HTTPS configuration is accepted; credential-bearing URLs and redirects are rejected. `ai.json` stores the base URL, model and secret reference, never the API key. Each turn resolves the named grant from Vault, so rotating the key applies to the next turn without a runtime restart.

The user-authorized local installation was configured from the sandbox user's Erebine OpenCode provider on `fleet`. Its source configuration was not modified. The API credential was transferred directly into encrypted Vault without printing it or writing a plaintext local credential file. No configuration or credential from that account ships with the package.

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

Prompts, the built-in/operator knowledge, runtime context and selected tool results are sent to the configured Erebine endpoint. API credentials are used only in the authorization header. Requests set `store: false`; this does not replace the provider's retention policy or establish zero-data-retention by itself. Inference may consume account credits.

Conversations and pending proposals stay in runtime memory. Up to 32 idle conversations are retained, with a one-hour idle expiry; context is reset when its configured size limit is reached. At most 48 conversations can perform inference concurrently. Background concurrency defaults to four and is operator-configurable from 1–48. Each turn has up to eight tool-capable model calls followed by one summarization call with tools disabled, six tool calls per model response, and 4096 output tokens per model request. Identical tools are cached within the turn; an exhausted budget returns collected results instead of discarding them. Requests have bounded timeouts and are not automatically retried. A timeout may still consume provider credits. Disconnecting cancels foreground inference and task watchers; background tasks continue until finished or explicitly cancelled.

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
