# Owned background-agent evidence

Kiln records background chat-worker events in
`STATE/ai-work-events/WORKER-ID/`. No hosted controller, external event database or
workflow engine is involved. This history is separate from saved conversations
and the older read-only investigation task system.

## Controls and evidence

In AI chat, `/events` shows the current agent's ordered timeline without stopping
work or sending another model prompt. `/events ID AFTER-SEQUENCE` pages another
owned worker's history. The composer remains available for guidance.

```text
ai work list
ai work timeline ID [AFTER-SEQUENCE]
ai work events ID [AFTER-SEQUENCE]
ai work watch ID
ai work input ID "Additional context"
ai work cancel ID
ai work remove ID
```

`timeline` abbreviates text for readability. `events` returns typed JSON with full
retained payloads. Use the last sequence as the next cursor. Pages contain at most
100 events and normally at most 2 MiB; a single larger event is returned intact
under the 8 MiB segment guard.

Typed events cover lifecycle, context queued/consumed, provider-visible reasoning,
answer deltas/replacement, activity, source inspections/drafts, provider labels,
tool starts/returns, cancellation and interruption. Sequences increase strictly.
Queued context has a stable ID. Consumption records the same ID before delivering
the message at a safe step. It means delivery to planning, not that a requested
change was applied. Live status shows queued and consumed counts.

Tool invocation awaits its durable start checkpoint before dispatch. Its return
records the controller result before conversation-size truncation. A start without
a return can mean rejected/interrupted dispatch, an in-flight tool, or a side
effect whose return was lost. It does not authorize retry. A returned result can
also report failure: inspect its payload and the authoritative application
change/release receipt.

The UI bounds its viewport; the journal retains raw provider-visible deltas. It
cannot retrieve hidden model reasoning. Credentials, provider headers and Vault
contents are not supplied to these callbacks. Prompts, tool arguments, source and
visible reasoning are private plaintext, not Vault-encrypted. Back them up as
private runtime state.

## Recovery and storage

Batches use Kiln's atomic write/fsync primitive, 0600 files and 0700 directories.
Writer locking and expected sequences reject stale runtime writes. Temporary
files are not committed events. Missing, corrupt, unsafe or misordered segments
reject recovery. This is local recovery history, not a tamper-proof audit service.

Restart reconstructs recorded progress, source and inbox, then commits an
interruption event for unfinished work. It never restarts inference or executes
a recorded tool. Inspect unmatched tool starts with application history/source
before starting a fresh task. Progress may be up to one 100 ms coalescing interval
ahead of disk; tool boundaries flush earlier progress. This does not claim
hardware power-loss guarantees.

Legacy `ai-work.json` snapshots migrate into initial checkpoints with a notice
that earlier intermediate events were not recorded. The original file is kept.
Removal hides a finished worker but retains evidence readable by its known ID and
owner. There is no automatic purge or silent eviction. Back up and deliberately
archive stopped runtime state before limits are reached; deleting arbitrary
segments creates a detected gap.

Resource guards: 4 MiB pending memory; 8 MiB per encoded batch; 32 MiB and 8,192
batches per worker; 200 non-removed workers; 512 retained worker namespaces.
Reaching a write guard stops work with an unconfirmed outcome instead of dropping
evidence or allowing another tool. These are storage/memory guards, not inference
pricing limits.

## Verification

`AIWorkEventTests` checks ordering, owner isolation, complete retained thinking,
context acknowledgements, stale writers, unsafe storage, missing segments,
archived visibility and tool dispatch blocked by checkpoint failure.

`scripts/agent-event-crash-acceptance.py` kills a separate fixture process with a
pending intent and checks restored progress, pending guidance, interruption, no
replay and successful independent new work in a new process. It uses no live
provider or application deployment.

`scripts/code-chat-acceptance.py` exercises `/events` over real SSH while an agent
works, draft/divider recovery, reattachment and context injection. Both harnesses
use disposable state. Local acceptance is separate from hosted validation and
live-provider publication acceptance.
