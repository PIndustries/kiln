# Application composition and loading

Status: the local process/SSH path and per-module loopback TCP ingress are implemented. Public TLS, host/path routing and cluster paths below remain proposed contracts.

## Two kinds of module

A **Swift library module** is compiled into an executable. Changing it requires rebuilding that executable.

A **deployable Kiln module** is an independently versioned executable release. It belongs to an application namespace, has its own OS process and can start or stop without restarting siblings. Its identity is `application/module`, for example `storefront/rest`.

```text
storefront (logical application)
  |
  +-- rest@0.1.0 process
  |     +-- HTTP Swift library
  |     +-- Domain Swift library
  |
  +-- websocket@0.1.0 process
  |     +-- WebSocket Swift library
  |     +-- Domain Swift library
  |
  +-- reports@0.1.0 process <-- install later while the others run
```

Shared domain library code does not imply shared memory or live state. Cross-process communication and persistent data must use explicit protocols/storage. The prototype examples do not yet communicate with one another.

## Implemented loading path

```text
Swift build outside Kiln
        |
Executable + JSON manifest
        |
app install /absolute/path/module.json
        |
Validate identity; copy executable to a new release directory
Persist module registration (stopped)
        |
app start storefront/rest
        |
Launch process with explicit arguments and a minimal environment
Capture stdout/stderr; persist desired running state
        |
app health storefront/rest
```

A manifest:

```json
{
  "application": "storefront",
  "name": "rest",
  "version": "0.1.0",
  "executable": "/absolute/path/to/backend",
  "arguments": ["--port", "18080"],
  "healthURL": "http://127.0.0.1:18080/health"
}
```

Legacy `app install` uses explicit health checks. Managed `app deploy` adds readiness admission, stable loopback ingress, draining and rollback; see [deployments](deployments.md). Releases are local executable copies using distinct worker ports. Artifact signing, architecture metadata and cluster routing remain future work. Applications must currently avoid spawning unmanaged descendant processes. Clean runtime shutdown stops direct children; persistent desired state starts them again on the next launch. A SIGKILL to the supervisor can leave children alive and requires operator reconciliation.

## Optional interfaces

KilnRuntime neither imports nor starts KilnSSH. The executable chooses whether to enable the SSH adapter. Local console and SSH dispatch to the same command engine. Future APIs and Apple UIs should use the same operations and authorization contract.

An optional built-in transport module and an installable application module are different extension mechanisms. The prototype SSH target is linked at build time and enabled at startup; dynamic installation/removal of platform interfaces is not implemented.

## Planned ingress and clustering

```text
client
   |
TLS ingress: host + path
   |
Logical service: storefront/rest
   |
Service directory: healthy instances + generation
   |
Local process or authenticated cross-node forwarding
```

The public route references service identity, never a hard-coded node. Installing a new module registers a service; readiness allows routing. Updates start a replacement generation, check health, shift new traffic and drain old connections. Long-lived WebSockets require an explicit reconnect/drain policy; sessions cannot silently migrate to new processes.

Nodes discover candidates, but join only after administrator-approved identity verification. Cluster membership, identity, scheduling, replicated desired state and fencing must exist before advertising cross-node placement or failover. A logical application may span nodes; persistent application data needs a separate replication/storage contract.

## Planned modules

- KilnIngress: routing, TLS, limits and connection draining.
- KilnDirectory: stable service names and health-aware instance resolution.
- KilnCluster: node identity, adoption, membership and control-state agreement.
- KilnPackages: Git/catalog resolution and verified immutable artifacts.
- KilnBuild: isolated compiler/test workers with scoped credentials.
- KilnSecrets: scoped provider interface and key lifecycle.

Builds, apps and interface services should remain outside the trusted supervisor process where practical. Native process boundaries contain application crashes but do not enforce security or resource isolation by themselves. Hard resource/security controls require platform-specific implementations.
