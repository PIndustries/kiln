# Module resource limits

Resource-aware manifests require Kiln 26.10.08.6 or later. Installing a resource-aware release upgrades the application index to format 2. Older dictionary-only runtimes reject that index instead of silently ignoring quotas. Once upgraded, the format remains 2 even if later releases remove their limits; use a compatible Kiln binary for node recovery.

A manifest can opt into Linux cgroup v2 enforcement for its worker and every descendant:

```json
"resources": {
  "memoryBytes": 134217728,
  "cpuMillis": 250,
  "maxProcesses": 32
}
```

`memoryBytes` sets `memory.max`; swap is disabled for this group. Values must be 64 MiB–1 TiB in 64 KiB increments. Memory pressure can terminate the group: `memory.oom.group=1` makes that an application-wide failure. Memory usage can temporarily exceed the kernel threshold while reclamation/OOM handling completes.

`cpuMillis` is CPU bandwidth: 1000 is one CPU, 250 is one quarter. The accepted range is 10–64000, enforced with a 100 ms `cpu.max` period. This applies to normal fair-scheduled workloads, not privileged realtime scheduling.

`maxProcesses` is 8–4096 **kernel tasks, including threads**, not just executable processes. Exceeding `pids.max` rejects new forks/threads. Choose enough capacity for Swift's runtime and the application's thread pools.

Omitting `resources` preserves existing trusted-worker behavior. macOS refuses manifests requesting these hard limits; it never silently substitutes monitoring. A Linux node without a writable delegated cgroup, the required controllers, or `cgroup.kill` also refuses to start a limited worker.

## Delegation

The supplied systemd unit adds:

```ini
Delegate=cpu memory pids
Environment=KILN_CGROUP_ROOT=auto
```

Use a dedicated unprivileged Kiln service account. `auto` finds the service's own unified cgroup. Kiln moves its supervisor into a `kiln-control` child and enables the delegated controllers for `kiln-workers`. Guardians stay outside worker limits so an OOM or exhausted PID quota does not prevent cleanup.

For a separately prepared delegated hierarchy, an operator can set `KILN_CGROUP_ROOT` to its absolute path beneath `/sys/fs/cgroup`. The supervisor must already belong to that group or its `kiln-control` child. Kiln refuses unrelated host cgroups and the hierarchy root. No SSH command grants arbitrary host cgroup access. It does not mount cgroup filesystems or invoke privileged shell commands to obtain delegation.

These are **resource quotas for trusted applications, not an OS security sandbox**. Workers still use Kiln's OS account. A deliberately hostile same-account program may tamper with its delegated controls or other same-account processes. Separate worker credentials, namespaces and filesystem confinement remain separate security work.

## Lifecycle and inspection

The guardian creates and verifies a unique cgroup before the application starts. Each concurrently running release generation has its own budget; a rolling deployment can temporarily consume the combined budgets of its active and draining generations. A native helper joins it before `exec`, so an application cannot fork in the interval between launch and resource attachment. Its children inherit membership.

`app resources APPLICATION/MODULE` reports the active generation's kernel limits, memory/CPU/PID counters and OOM/fork-denial events. After exit it reports the last retained outcome. An unbounded legacy worker is explicitly identified as such.

On stop, the direct worker receives SIGTERM and has three seconds to exit; then Kiln kills it if necessary. `cgroup.kill` terminates all remaining descendants, including daemonized children. Kiln checks the group is empty before removing ownership. A private generation ledger also lets startup—or an explicit start after guardian failure—reclaim only Kiln's recorded groups. An unresolved cleanup fails closed instead of starting overlapping workers. A whole OS reboot removes the old cgroups; desired workers are recreated with fresh generations and the same configured quotas.

Resource controls do not currently impose disk quotas, log-size limits, network bandwidth limits, or per-module OS user identities.

The kernel interface is defined by the [Linux cgroup v2 documentation](https://docs.kernel.org/admin-guide/cgroup-v2.html); service delegation is described in [systemd resource control](https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html).
