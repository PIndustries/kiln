# Ecosystem direction

Design requirements and core priorities for Kiln. README and capability-specific documentation record implemented behavior; contracts below remain future work unless explicitly marked.

## Core punch list (2026-10-24)

Kiln has a working single-node operations foundation: independent processes,
deployment/readiness/rollback, identity and Vault controls, ordinary SSH, native
AI providers, approved operations and durable investigation/recovery records.
The next milestones should finish complete operator journeys. The items below
are gaps and acceptance targets, not claims that these capabilities have shipped.

First foreground-continuity milestone: opt-in named conversations now retain bounded
prompts, answers, provider-visible thinking and controller receipts across SSH reconnect
and runtime restart. Local JSON cursors, retention/deletion and key/role/grant isolation
are implemented; interactive approvals never revive through transcript replay.
Application-specific context, richer typed tool/task/approval event replay, streaming API
backpressure and evidence-based compaction remain open under #40 and #20.

| Order | Gap | Acceptance target |
| --- | --- | --- |
| 1 | Foreground continuity ([#40](https://github.com/PIndustries/kiln/issues/40)) | Reconnect to an identity/application-scoped named conversation with retained transcript and task references. Add retention/deletion, ordered replay and restart/revocation tests. Never replay a mutation merely to restore a view. |
| 2 | Visible readiness | Distinguish configured profiles, locally available credentials and live-verified provider/model behavior. Show running build revision and actionable recovery steps. Local AI setup checks cover only part of this journey; remote authentication, quota and inference need separate evidence. |
| 3 | Full-node recovery | Rehearse restore into a clean destination with state, separately protected Vault keys, application data and compatible binaries. Verify revoked access, stopped intent, operation receipts and migration boundaries. Existing storage/Vault tests do not establish a complete disaster-recovery experience. |
| 4 | Stable operator API ([#20](https://github.com/PIndustries/kiln/issues/20)) | Version authenticated status/task/approval/event/receipt contracts, with reconnect cursors, revocation and compatibility tests. SSH and later clients share the same authorization; application HTTP examples are not a management API. |
| 5 | Application state and a reference application ([#15](https://github.com/PIndustries/kiln/issues/15)) | REST and WebSocket modules share scoped durable state using atomic/versioned operations, with backup, migrations and explicit rollback limits. Define cache and job semantics separately. Prove a complete install/update/recovery journey before adding a catalog of templates. |
| 6 | Workload isolation ([#44](https://github.com/PIndustries/kiln/issues/44)) | Establish OS-enforced filesystem, process, credential and network boundaries before admitting third-party code or AI coding tools. Management roles and Linux resource limits already serve narrower purposes; same-UID trusted processes remain outside a hostile-code sandbox. |
| 7 | Budgets and outcome evidence ([#45](https://github.com/PIndustries/kiln/issues/45)) | Persist run/provider/model/tool versions, usage when supplied, time limits, approvals and authoritative outcomes. Enforce run budgets and evaluate quota, fabricated success, prompt injection and uncertain writes. Keep estimates separate from provider-reported usage. |
| 8 | Extensible tools and durable workflows ([#41](https://github.com/PIndustries/kiln/issues/41), [#43](https://github.com/PIndustries/kiln/issues/43)) | Introduce typed, versioned tool contracts and reduced-capability profiles before workflow steps, delegation or schedules. Define cancellation, retries and idempotency outside prompts. Existing independent investigations are not a dependency graph or scheduler. |
| 9 | Public application ingress ([#7](https://github.com/PIndustries/kiln/issues/7)) | Implement route ownership, TLS termination, certificate renewal and expired/failed-renewal behavior before exposing public web applications. Existing loopback routing does not supply this layer. |
| Ongoing gate | Native-client and sustained-load acceptance ([#9](https://github.com/PIndustries/kiln/issues/9)) | Extend the recorded Apple Terminal/OpenSSH acceptance to additional clients and long sessions with multiple operators, cancellation, restart and overload. Record exact revisions and live-provider evidence separately from fixtures. Keep hosted macOS/Linux gates and make redundant CI work visible. |

The next larger product milestone is foreground reconnect/resume, designed with
the operator event contract. Local diagnostics can improve onboarding while that
work proceeds. Portable application bundles, appliance formats, optional Git and
registry hosting, automatic cluster placement/failover and native Apple clients
remain later work. Cluster automation still requires ownership/fencing design;
adding nodes does not create replicated state or safe failover.

## Source and prebuilt distribution

All installation methods should produce the same release contract:

```text
GitHub / private Git / Kiln-hosted Git
              |
       Isolated build worker
       pinned commit + toolchain + dependencies
              |
              +--------> Immutable release <------- Precompiled artifact
                                  |                 public/private registry
                         Verify digest/signature
                         OS / architecture / SDK compatibility
                                  |
                         Install -> start -> ready
                                  |
                          Service directory
```

Separate provider interfaces cover source retrieval, credential retrieval, build execution, artifact storage and release verification. Git credentials must not become application credentials. The supervisor must not execute build plugins or repository scripts in its own process. A source build is code execution and needs isolated build workers before use with untrusted repositories.

A release should include executables, static assets, migrations, requested capabilities and its SDK/protocol compatibility. Credentials belong in scoped providers, never Git URLs, manifests or logs. Deployment should activate a verified release and maintain an older release for rollback; data migration rollback is a separate contract.

Kiln-hosted Git and an artifact registry can be optional installed services using the same provider contracts as external hosts. A single-server installation should not require operating separate external services, but installed applications must not bypass permission boundaries.

## Web applications

The first [KilnWeb framework milestone](web-framework.md) provides controller routes,
escaped HTML composition, browser/CSRF boundaries and server-rendered live views
with process-local broadcasts. A separate demo worker proves two-browser updates and managed loopback
ingress deployment, upgrade and rollback.
Foreground administrator AI can discover its current tools, learn the built-in
KilnWeb API guide, inspect registered source, compile-check and correct proposed
edits, publish a healthy isolated development worker and inspect the app's HTTP
response. Source scope is one explicitly registered file per app; arbitrary
repositories, dependencies and production publishing remain separate capabilities.
DOM diffing, durable application data, distributed live state and public routing
remain outside this milestone.

Provide optional REST, WebSocket, static-site and server-rendered HTML modules. A web page renderer calls application services and receives scoped access to state; it does not query another process's memory. Static files and templates are versioned release assets. Host/path routes target logical services. Browser sessions, CSRF protection, output escaping and authorization require explicit framework contracts.

## Shared state

All instances of a logical service should address the same application-scoped state namespace through KilnKit. Shared state is a service/API contract, not pointers shared between native processes.

```text
REST instances ---------+
WebSocket instances ----+--> Kiln state API --> authoritative state service
SSH management ---------+       |                     |
                         identity/capabilities       durable log/storage
                                                       |
                                                  replication
```

Keep three semantics distinct behind a cohesive SDK:

- **Cache:** expendable values, TTLs, bounded memory and explicit eviction.
- **Durable records:** typed key/value or document data, persistence, atomic operations and a declared consistency model.
- **Events/jobs:** delivery and acknowledgement semantics, retries, idempotency and ordering where specified.

An ordinary get followed by put is not a safe distributed increment. The API needs operations such as compare-and-swap or atomic increment, concurrency/version checks, namespaces and size limits. Pub/sub alone is not durable job delivery. Disconnecting or partitioning a node must produce explicit errors or documented stale reads, not silently divergent authoritative state.

The long-term goal is a Kiln-owned data API, administration experience and bundled service. Begin with a proven embedded persistence engine behind this API; a custom storage engine and distributed replication system would be a substantial independent project. Owning the product does not require replacing every storage primitive.

Replication does not happen automatically because nodes discover one another. Membership/adoption, a chosen agreement protocol, leader/ownership fencing, replica placement, snapshots, log recovery, backups and restore testing are prerequisites. A two-node partition cannot preserve both majority-based write availability and a single consistent authority. Cache replication and durable-data replication may use different policies.

Application instance scaling and database replica scaling are distinct decisions. Scaling workloads over already adopted nodes differs from provisioning new machines; provisioning requires provider integrations. Adding a worker node must not silently change the voting membership of the data/control cluster. New replicas require catch-up and health verification before serving authoritative traffic. Stateful storage cannot be autoscaled like stateless HTTP workers.

## SSH interoperability

KilnSSH uses Apple's SwiftNIO SSH implementation of SSHv2. The intended wire contract is the SSH RFC family and supported extensions, not a proprietary transport. OpenSSH is an implementation with additional features/extensions; it is not the name of a single RFC.

The prototype verifies OpenSSH public-key authentication, exec requests, PTY shell requests, channel output and exit status. It supports Ed25519 host keys and the authentication/key-exchange capabilities provided by the pinned NIOSSH dependency. It does not implement SFTP, host OS shell execution, agent forwarding or arbitrary port forwarding. These requests must fail explicitly. No universal client-compatibility claim is made: algorithm negotiation, terminal behavior and supported clients require a compatibility matrix and tests. OpenSSH may warn that this connection does not negotiate post-quantum key exchange.

## Delivery

A signed platform-specific binary is the simplest entry point. A Linux appliance may package the same runtime into QCOW2/installer images, with bootc providing OS image updates. OS updates, runtime updates and application updates have different lifecycles. Mutable application state must live outside the immutable OS image. Linux core runtime tests now pass. Appliance boot and cross-node behavior remain unverified in this prototype.
