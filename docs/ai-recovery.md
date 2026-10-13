# Durable AI recovery

Recovery tasks connect an unhealthy module, an explicit restart approval and evidence from the replacement process. The model can request an investigation through `create_recovery_task`; it cannot approve the restart or decide that recovery succeeded.

In chat, enter `/recover storefront/rest`, or ask Kiln to investigate recovery of that module. Without a configured AI provider, use SSH commands:

```text
ai recovery new storefront/rest
ai recovery list
ai task show recovery:<id>
```

The task appears in the Tasks sidebar. If its configured health check fails, a restart proposal appears in Approvals. Select it and click Approve or Deny. `ai approve recovery:<id>` and `ai deny recovery:<id>` provide the same controls from the CLI.

```text
Investigate process and HTTP health
    +-- healthy ----------> retain evidence; no change
    +-- no health check --> needs review; no change
    +-- unhealthy --------> approval for exact generation
                                |
                         consume approval durably
                                |
                         record restart intent
                                |
                         restart once per request ID
                                |
                         receipt + generation + HTTP 200
                                +-- match ---> recovered
                                +-- unclear -> needs review
```

Recovery is administrator-only and bound to the original identity name and SSH public key. Reconnecting with that identity preserves access to its records and approvals. Permissions are checked again at execution. Approvals expire after five minutes; changes to the runtime, installation or worker generation invalidate stale approvals. Restarting may interrupt traffic and disconnect WebSocket clients.

`recovered` means the runtime recorded a successful restart and subsequently observed that same replacement generation running with HTTP 200 at its configured health endpoint. A PID alone, a model response or an unrelated healthy process cannot establish recovery. Verification allows a short bounded startup window; a slower application may require reconciliation.

## Interrupted work

SSH disconnection does not stop the task. Runtime restart retains the journal but does not replay an uncertain mutation. To inspect its receipt and current health without repeating the restart:

```text
ai recovery reconcile recovery:<id>
ai task show recovery:<id>
```

This is not an exactly-once transaction across process failure. If the runtime stops between a side effect and its receipt, the outcome stays unconfirmed. Repeated approval requests cannot execute that consumed approval again. A new runtime generation also prevents old receipts from certifying a newly restored worker.

After investigating an unconfirmed task, an administrator can explicitly close it with `ai recovery close recovery:<id>`. Closing acknowledges uncertainty; it does not claim success. It permits a fresh recovery request with a new approval. Finished records can be removed with `ai task remove recovery:<id>`; operation receipts remain.

## Bounds and validation

The controller allows four concurrent recovery workers, one active recovery per module, 100 retained records and a 2 MiB journal. Recovery supports restart only. It does not provide general shell access, automatic failover, autonomous approval, or distributed scheduling.

Unit tests cover identity ownership, duplicate approval, expiry, revocation, failed persistence, corrupt journals, interrupted execution and stale generations. `python3 scripts/ai-recovery-integration.py` uses disposable SSH connections and a real HTTP worker to verify one approved restart, healthy replacement evidence and retention without replay after runtime restart. Both macOS and Linux server CI run this fixture.
