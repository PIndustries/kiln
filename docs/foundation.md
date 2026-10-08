# Server foundation acceptance

This milestone adds named operator identity, scoped authorization, enforced Linux resource budgets, and authenticated peer-node management to the existing crash-safe single-node runtime. It does not turn trusted application executables into a malicious-code sandbox or implement a replicated application database.

## Required end-to-end evidence

- Two named SSH users receive different permissions. A viewer cannot mutate an application, retrieve credentials, attach a remote shell, or gain those powers through AI tools or terminal actions.
- An operator can manage an explicitly granted module but cannot access a sibling module. Revocation affects subsequent requests on an existing session. The final administrator cannot be removed accidentally.
- Persisted identity policy survives restart. Audit records identify the principal, action and outcome without storing credential values or AI prompts.
- A Linux worker exceeds its memory or process budget without taking down Kiln or a sibling. CPU quotas are visible in the kernel. Descendants are cleaned up. Unsupported platforms reject requested hard limits.
- Two independently running nodes discover one another without automatically trusting one another. Fingerprint adoption enables authenticated, encrypted, typed operations; revocation disables them again.
- Repeated or interrupted remote operations are reconciled without blindly replaying a mutation. Offline peers are reported as unavailable.
- Existing deployment, rollback, SSH/HTTP/WebSocket, Vault, AI-policy and crash-recovery tests remain green on macOS and Linux.

## Scope boundaries

Peer membership and remote administration are the first cluster layer. They must not be advertised as consensus, automatic workload placement, replicated desired state, automatic failover or transparent connection migration. Those require separate fencing and data-ownership contracts.

Linux resource budgets constrain cooperative/trusted application workloads. Shared OS-user access remains a separate boundary from Kiln's management-plane roles. Host-administrator and arbitrary trusted executable privileges cannot be revoked by an SSH command policy.

Native clients, a package/build registry, public TLS/DNS/tunnel integrations, and replicated storage remain separate ecosystem work. Release verification records distinguish tested behavior from these planned capabilities.
