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

CI artifacts are validation candidates. Publishing a binary release requires
clean-host installation evidence, release notes and the gates in
[release readiness](release-readiness.md). Artifact production alone does not
satisfy those gates.
