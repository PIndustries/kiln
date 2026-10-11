# Binary packages

`python3 scripts/package-release.py --output /absolute/path/outside-checkout`
builds an optimized package from a clean Git revision using Swift 6.2.3 and
`Package.resolved`. Supported build hosts are Apple Silicon macOS and Linux
x86_64. Distribution documents are read from the recorded Git commit, so ignored local
files and symlink targets cannot enter the archive. The script never packages
local runtime state or a whole working directory.

Each archive contains the runtime, example backend, documentation, Apache license,
dependency notices and `build-info.json`. The manifest records the source revision,
compiler, resolved-dependency digest, dynamic dependencies and file checksums.
The adjacent SHA-256 file covers the archive. Checksums detect corruption; they
are not a signature or proof that an untrusted download came from P.Industries.
Stable archive metadata does not imply bit-for-bit reproducible compiler output.

## Install and verify

On macOS, use `shasum -a 256 -c <archive>.sha256`; on Linux, use
`sha256sum -c <archive>.sha256`. Extract into a new version-specific directory,
inspect `build-info.json`, and run `bin/kiln --version` before starting a node.
Use an absolute state directory outside the extracted package. Follow the README
for public-key enrollment and the REST/WebSocket example. Generate packaged
example manifests with `python3 scripts/example-manifests.py --output /tmp/kiln-examples
--executable "$PWD/bin/kiln-example-backend"` (as one command from the extracted
package directory); the source-tree default points to a debug build.

macOS packages require macOS 14 or later. They are not currently notarized.
Linux packages require the Swift 6.2.3 runtime and the distribution libraries
listed in `build-info.json`. They do not bundle a Linux distribution or Swift
runtime. The CI build uses the official `swift:6.2.3` environment; compatibility
with another distribution must be tested rather than inferred from architecture.

## Upgrade and rollback

Keep the current package intact. Extract and verify a new package in a separate
directory; never overwrite a running executable. Back up runtime state and its
separately stored Vault key using the documented operational procedure. Validate
the candidate with disposable state before an intentional runtime restart.
Runtime replacement can disconnect management clients; independent application
release deployment is a separate operation.

Retain the previous compatible package and backup until checks on the new runtime
pass. A binary rollback does not automatically undo state format changes; review
release-specific compatibility before pointing an older runtime at newer state.

CI scans the final compressed artifacts for credentials before uploading them.
A scan failure blocks upload; detection still has the limits described in
[credential incidents](credential-incidents.md).

CI artifacts are validation candidates. Publishing a binary release requires
clean-host installation evidence, release notes and the gates in
[release readiness](release-readiness.md). Artifact production alone does not
satisfy those gates.

## Clean-install CI boundary

The package workflow also downloads each scanned candidate artifact into a separate
job and verifies its archive checksum, source revision and every manifest file digest
before running the real OpenSSH/REST/WebSocket integration suite against its extracted
executables. The test harness is checked out at the same revision; no binaries are rebuilt
in these jobs.

- **macOS:** a fresh Apple Silicon `macos-15` runner installs no additional Swift
  toolchain. It still has the hosted image's standard Xcode installation and is not
  proof of a machine with all developer tools removed, or the minimum macOS 14 version.
- **Linux:** a fresh Ubuntu 24.04 container installs distribution runtime libraries and
  receives only the `.so` runtime libraries from the official `swift:6.2.3` image.
  The test asserts that neither `swift` nor `swiftc` is on PATH. Only the downloaded
  candidate, those runtime libraries and the integration harness are mounted; there is
  no compiler image, source checkout or build tree inside the test container. The host
  requires explicit completion, checksum and final integration markers from inside
  the container; a successful package-manager exit alone is not test evidence.

Linux consumers still need to provision the Swift 6.2.3 shared runtime and the
appropriate distribution libraries separately. CI records the source image digest;
these libraries are test prerequisites, not newly bundled release contents. This check
establishes Ubuntu 24.04 user-space execution, not systemd/cgroup enforcement, another
Linux distribution, an OS reboot or a completely static executable. The separate server
resource job covers actual kernel enforcement.

These clean-install jobs improve candidate evidence but do not publish a release or
complete the remaining release-note, upgrade/recovery and distribution acceptance gates.

## Upgrade and rollback rehearsal

Package CI runs `scripts/package-upgrade-integration.py --candidate /extracted/package`
against a pinned public baseline (`360e36e`, release 26.10.09.1). The harness builds
that exact baseline into a separate temporary package using its own committed
packaging script; it neither uploads that baseline nor publishes a release. Both
packages must pass their file manifests and report different release versions.

The rehearsal provisions only disposable state: an SSH identity, encrypted Vault
with a separately stored key, an explicitly granted REST module, a WebSocket module,
a deliberately stopped module and an ungranted module. After a clean stop, it makes
a cold state backup and separate key backup. It starts the candidate against that
same state, checks health and actual WebSocket traffic, then switches back to the
original package and repeats the checks. Private state digests, application data,
secret grant/denial behavior and both package executables must remain unchanged.
The integration log must contain an explicit completion marker before CI accepts it.

This proves compatible-state binary rollback for this specific version pair; it
cannot authorize arbitrary downgrades or reverse future schema migrations. It stops
the runtime and its separate session service between versions, so it does not promise
live SSH/session continuity. A release with an incompatible state format needs its
own migration and backup-restore acceptance evidence. The rehearsal does not publish
a tag, overwrite a running executable or contact a paid provider.
