# Portable application directory bundles

A bundle carries one module's executable, assets and shared libraries for one
declared target: `macos-arm64` or `linux-x86_64`. Kiln copies only the declared
files into a versioned release and checks their SHA-256 digests. The original
bundle can then be moved or deleted. Executables remain trusted programs running
as Kiln's OS user; a checksum is not publisher authentication or a code sandbox.

## Create a bundle

Compile the program and libraries for the target first. Arrange an explicitly
selected payload directory, for example:

```text
payload/
  bin/api
  assets/index.html
  lib/libexample.so
```

Create a module manifest whose executable is relative to that payload:

```json
{
  "application": "demo",
  "name": "api",
  "version": "1",
  "executable": "bin/api",
  "arguments": [],
  "healthURL": "http://127.0.0.1:8001/health",
  "ingressPort": 8000
}
```

The producer helper requires Python 3.11 or later; installed applications do not
need Python or a compiler unless the application itself depends on them.

```sh
python3 scripts/application-bundle.py --manifest module.json \
  --payload /absolute/payload --output /absolute/artifacts/demo-api-1 \
  --platform linux-x86_64
```

The output must be new and outside the payload. Everything under the explicitly
selected payload is included, so prepare a dedicated tree containing only the
application's distributable files. The helper generates `bundle.json` with
`formatVersion: 1`, the target, module manifest and each file's relative path,
SHA-256 and executable flag. There are no download, build or installation hooks.
Plain executable manifests continue to work without bundle metadata.

## Install, deploy and roll back

In Kiln's command drawer or SSH exec interface:

```text
app install /absolute/artifacts/demo-api-1
app start demo/api
app releases demo/api
app deploy /absolute/artifacts/demo-api-2
app rollback demo/api
```

Installation accepts the bundle **directory**, not its `bundle.json` path.
Deployment requires stable ingress and a distinct worker/health port, just as
plain executable deployment does. The complete previous payload is retained for
rollback. Corrupt payloads and unhealthy candidates do not replace the active
release. `app releases` reports the active bundle target, file count and manifest
digest. Install/deploy authorization, scoped Vault bindings, resource policies,
readiness, worker ownership and ingress draining use the existing runtime paths.

`KILN_RELEASE_DIR` points to the versioned payload; read assets relative to it.
`KILN_DATA_DIR` and the worker's current directory remain persistent application
data. Each generation receives its own release path. Data migrations are the
application's responsibility: candidate startup can change shared data before a
readiness failure, and binary rollback does not reverse those changes.

Libraries must already use relocatable loader references: for example,
`$ORIGIN/../lib` on Linux or `@executable_path/../lib` and an appropriate `@rpath`
install name on macOS. Kiln does not rewrite binaries or inject `LD_`/`DYLD_`
search paths. The target declaration is admission metadata; the producer still
must supply compatible binaries and document any required OS libraries.

## Integrity and recovery boundaries

- Bundle metadata is limited to 2 MiB and 1–4096 files. Files are limited to
  256 MiB each and 512 MiB total, streamed in bounded chunks.
- Payload paths use ASCII letters/digits, dots, underscores, hyphens and `/`.
  Absolute/traversing paths, case aliases, file/directory collisions, symbolic
  links and special files are rejected. Root `bundle.json` is reserved.
- Only declared files are copied. Copied bytes must match their digests before
  activation, and the installed manifest and payload are checked again before
  starting/restoring a worker. Release files are installed without write bits;
  this does not stop a trusted program running as the same OS user changing them.
- Copying and integrity reads run outside the runtime actor so large payload I/O does not hold its
  management executor. Failed copies are removed; interrupted promotion uses
  the existing durable pending-release reconciliation.
- **The first bundle install upgrades application state to format 3.** Earlier
  runtimes, including packaged `26.10.23.2`, reject it. Keep a compatible runtime
  for application rollback. Returning to an older runtime requires an appropriate
  pre-bundle state backup and separately stored Vault key; do not blindly point
  the older binary at newer state. Nodes using only legacy manifests retain
  their existing state format and compatible rollback behavior.

This milestone uses local directories. Archive extraction, publisher signatures,
registries, remote fetching, cross-compilation and migration automation require
separate contracts and acceptance.

## Repeatable acceptance

`python3 scripts/bundle-integration.py` compiles disposable native C workers and
shared libraries and exercises real SSH installation, source deletion, assets,
relative library loading, persistent data, deployment, corrupt/unhealthy rejection,
cold restore and full-payload rollback. `--legacy-bin /path/to/older/kiln` also
checks that the old runtime rejects bundle state without changing its index.
Both server platforms and the packaged-runtime jobs run the bundle lifecycle
check. Unit tests cover admission, partial-release cleanup and tampering.
