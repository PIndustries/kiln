# Kiln AI — native Erebine integration

Kiln AI is a Swift library and SSH chat interface using Foundation HTTP directly against Erebine's chat-completions API. OpenCode is not invoked or required at runtime. The module implements conversation history, a bounded tool loop, local operation proposals, Vault-backed credentials and versioned operator knowledge.

## Chat

In Kiln's SSH dashboard, open the backtick drawer and type:

```text
ai
```

The drawer becomes a chat panel. Ask naturally, for example:

- "Which modules are running? Check their health."
- "Report host memory and CPU."
- "Explain how rollback works in Kiln."
- "Propose restarting storefront/rest."

Responses wrap to the terminal width. Page Up/Down scrolls output. `/exit` returns to commands, `/reset` clears that session's context and proposals. This version displays completed responses, not a streaming token feed.

Read-only tools run automatically. A requested change produces an exact `app start`, `stop`, `restart` or `rollback` proposal. It does not execute based on model prose. Review the module/action, then use `/approve ID` or `/deny ID`. Approvals belong to the originating SSH session, expire after five minutes, and can be consumed only once. If the module's process state, PID or version changed since the proposal, execution is refused. A consumed proposal is not automatically retried after failure.

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

Available reads: runtime status, module list, host metrics, per-module health, active/previous releases and ingress address.

Available proposed changes: start, stop, restart and rollback of an already-installed module. The supervisor checks the module generation before execution. No model-produced string is passed to a host shell or general-purpose command dispatcher.

Not exposed: Vault values or grant management, application logs, arbitrary files, server execution, network browsing, installation/deployment from arbitrary paths, and provider account administration. Terminal output is sanitized by the existing TUI renderer.

The model can still make mistakes or write misleading prose. The locally generated proposal and execution result are the authoritative action record. Permission enforcement lives in Swift rather than in the system prompt.

## Data, cost and operational boundaries

Prompts, the built-in/operator knowledge, runtime context and selected tool results are sent to the configured Erebine endpoint. API credentials are used only in the authorization header. Requests set `store: false`; this does not replace the provider's retention policy or establish zero-data-retention by itself. Inference may consume account credits.

Conversations and pending proposals stay in runtime memory. Up to 32 idle conversations are retained, with a one-hour idle expiry; context is reset when its configured size limit is reached. At most four conversations can perform inference concurrently. Each turn has at most five model calls, six tool calls per model response, and 4096 output tokens per model request. Requests have bounded timeouts and are not automatically retried. A timeout may still consume provider credits. Disconnecting does not necessarily cancel an in-flight model request; it cannot bypass local approval.

This is an integrated runtime module, not yet an independently hot-replaceable AI service. The framework target uses Foundation/FoundationNetworking and supports headless design; runtime and live-provider validation were performed on macOS. Linux execution is not yet verified.

## Verification and references

`swift test` includes deterministic policy tests using a test transport: unavailable tools, credential exclusion from messages, read tools, knowledge updates, session-bound single-use proposals and native chat commands. These tests do not contact Erebine.

The opt-in scripts `ai-live-integration.py` and `ai-terminal-integration.py` use real Erebine inference and disposable Swift workers, with an operator-supplied configured Vault. They can consume API credits. They verify live reports, tool calls, proposal-before-execution, explicit approval, rejected replay, knowledge reload and the real SSH chat view.

API implementation references: [Erebine Chat Completions](https://erebine.ai/docs/api-reference), [Tool Calling](https://erebine.ai/docs/tool-calling), and [OpenCode provider configuration](https://erebine.ai/docs/opencode).
