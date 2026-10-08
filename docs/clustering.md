# Explicit peer adoption and remote module control

Kiln's first cluster layer connects independently supervised nodes. It provides native Swift SSH transport, persistent node identity, explicit peer trust, liveness probes and typed remote module operations. It does not implement a scheduler, quorum, automatic failover, replicated state/database, or cluster-wide ingress routing.

## Start and discover

The operator SSH listener and peer listener are separate. Peer transport cannot open a shell, PTY, arbitrary exec command or forwarding channel. Start the optional peer service with:

```sh
kiln up --state /var/lib/kiln --authorized-keys /etc/kiln/admin.pub \
  --cluster-host 127.0.0.1 --cluster-port 2223
```

Use a private reachable address for communication between hosts. The default is loopback. In each node's administrator CLI:

```text
node identity
node discover 192.0.2.20 2223
node adoption list
node accept SHA256:<verified-fingerprint>
```

Compare the candidate against `node identity` obtained through a separately authenticated session on the intended node. Discovery never establishes trust. Repeat discovery and acceptance in the other direction: both nodes must adopt each other before remote operations work. Adoption grants administrative node control; only administrator identities can administer this interface. A receiver identifies the sending node by its adopted key. Individual SSH-user identities are not federated between nodes; the caller node records its local administrator in its command audit.

For optional IPv4 LAN discovery, explicitly provide `--discovery-port 2224` and a peer listener reachable on the private network. Nodes advertise an Ed25519 public key and peer port on multicast group `239.255.75.76`, with multicast TTL 1. Candidates use the observed packet source address and expire after two minutes. The receiver accepts at most eight datagrams per second, 512 bytes each, and retains at most 128 candidates. Advertisements remain in memory and never change an adopted endpoint or activate a node. Networks that filter multicast can use `node discover` instead.

The native peer transport pins the adopted server key and requires the caller's explicitly adopted node key. It uses SwiftNIO SSH's standard encrypted, authenticated SSH protocol; Kiln does not implement its own cryptography. The node's private Ed25519 key lives at `STATE/cluster/node-ed25519`, mode 0600, inside private state. Copying that state duplicates the identity; provision fresh state for a new node.

## Operate and inspect

```text
node list
node status SHA256:<peer>
node start SHA256:<peer> my-app/api
node stop SHA256:<peer> my-app/api
node restart SHA256:<peer> my-app/api
node operations
node receipt SHA256:<peer> <request-uuid>
node revoke SHA256:<peer>
```

`node list` reports the last actual probe result and timestamp. AI can read this inventory through its administrator-only `cluster_status` tool; remote peer mutations are available through the administrator CLI, not through AI tools. Heartbeats run in bounded groups of four; an unreachable peer is not treated as dead for scheduling or takeover. Remote operations are limited to module inventory, start, stop and restart. Revocation denies future requests, including requests on already authenticated connections. An operation already authorized and dispatched may still finish.

There are at most 32 accepted peers and 64 simultaneous incoming peer connections. Separately, at most 32 incoming operations may remain dispatched, including work whose client disconnected, and 16 outgoing calls may be active. Reaching these limits rejects new work before dispatch. Concurrent sends of the same mutation ID are refused. A persisted request with an uncertain outcome is never retransmitted; use its receipt to inspect the existing operation. Each connection supports one typed request, has a bounded lifetime, and has no general command interpreter. Requests and responses have size limits.

## Failure and idempotency

Before transmitting a mutation, the caller persists an outbound UUID, target peer and exact operation. Before executing it, the receiver persists a receipt. Repeating the same UUID and payload returns the existing outcome; changing the actor or payload for that UUID is rejected. New mutations more than five minutes outside the receiver's clock are rejected, so keep node clocks synchronized.

A timeout, disconnected client, or node crash can leave an uncertain outcome. Errors identify the original request UUID; `node operations` recovers it after caller restart. Use `node receipt` to inspect the receiver. Receipt lookup never starts a missing operation. A confirmed receiver outcome updates the matching local outbound journal; a missing or unconfirmed receipt leaves the local uncertainty intact. A receiver receipt left at `started` is reported as `unconfirmed`, not replayed. Inspect module state before deciding on any new operation. This provides durable deduplication and honest uncertainty, not exactly-once execution across arbitrary crashes.

`node operations` shows at most 100 entries, with unconfirmed outcomes first and newest timestamps first within each group. It reports truncation explicitly; older records remain available through protected local state.

Completed receipts survive restart. Journals stop accepting new mutations at 10,000 entries instead of silently discarding deduplication history. Receipt rotation requires an explicit retention design before long-running high-volume operation. An uncertain peer-trust persistence result closes authorization until process restart/reconciliation.

An ordinary sender disconnect does not cancel an accepted receiver operation. Shutting down the peer service rejects new work; already dispatched operations retain their receipts and finish through the runtime's shutdown behavior.

## Validation

`swift test --filter cluster` exercises native SSH pinning, mutual adoption, negative authorization, replay conflicts, durable receipts and interrupted-operation handling.

`python3 scripts/cluster-integration.py` starts two real loopback Kiln processes. It discovers/adopts them, manages a real worker remotely, revokes access, kills a sender during a remote restart, and verifies the receiver executes once and the restarted sender can inspect its receipt. It also verifies offline reporting and identity/trust/receipt persistence across both-node restart.

`KILN_TEST_MULTICAST=1 python3 scripts/cluster-integration.py` additionally enables real multicast discovery. Run this variant in an isolated network/container: it intentionally binds peer listeners to all IPv4 interfaces and emits LAN discovery advertisements.
