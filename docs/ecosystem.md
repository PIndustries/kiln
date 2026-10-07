# Ecosystem direction

Design requirements collected for Kiln. Except where README explicitly states implementation, this document describes future work.

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

A signed platform-specific binary is the simplest entry point. A Linux appliance may package the same runtime into QCOW2/installer images, with bootc providing OS image updates. OS updates, runtime updates and application updates have different lifecycles. Mutable application state must live outside the immutable OS image. Linux, appliance boot and cross-node behavior remain unverified in this prototype.
