# Secret scanning and credential incidents

## Continuous checks

The **Secret scanning / scan** check runs on pull requests, pushes to `main`, and published or edited releases. It scans all fetched reachable Git history and tracked working files, including examples and fixtures. The release event additionally downloads release assets and scans their contents without executing them. Manual dispatch accepts an optional existing release tag for the same asset check. A release without assets fails the asset scan rather than claiming that a package was inspected.

Gitleaks is pinned to 8.30.1. `scripts/install-gitleaks.py` verifies hard-coded SHA-256 digests from that upstream release before installing its executable. Updates must review both the version and checksums, rerun the synthetic canary, and review changed findings. Workflow permissions are read-only; pull requests receive no provider credentials. Maintain branch protection so this check must pass before merge, and review scanner/configuration changes as security-sensitive code.

Run locally with the pinned scanner on `PATH`:

```sh
python3 scripts/secret-scan-test.py
python3 scripts/secret-scan.py --history --tree --output /tmp/kiln-secret-reports
python3 scripts/secret-scan.py --artifacts /path/to/candidate-packages --output /tmp/kiln-secret-reports
```

The artifact command is the pre-upload interface for release packaging. Run it **before** publishing candidate packages. The `release` event is a subsequent check: it cannot prevent a secret from being public between an upload and detection. New assets added after a release event need another edited/manual run. Release packaging must scan the final bytes again after any rebuild or archive modification.

Exit status is 0 for a completed clean scan, 1 for findings, and 2 for incomplete checks. An empty/missing artifact directory and scanner errors fail closed. The tree scan copies tracked working files, including modifications; untracked files must be added to Git or scanned explicitly as artifacts. History coverage is limited to fetched refs; use a full clone, not a shallow checkout. Symlinks in the tracked tree require explicit review and fail the scan.

## Exclusions and reporting

The default Gitleaks rule set remains enabled. The only content exclusion matches only the complete uninitialized Swift declaration of a `key` or `privateKey` binding with type `Curve25519.Signing.PrivateKey`. These have no assigned value. It does not exclude Swift files, test fixtures, documentation, or generic API-key detection. `.gitleaksignore` retains two exact reviewed historical declaration fingerprints, not path-wide exclusions. Inline `gitleaks:allow` comments and ignore files inside downloaded artifacts cannot suppress this workflow.

The canary test creates a random, nonfunctional provider-shaped token only in a disposable directory. It verifies detection even beside a permitted declaration, despite inline suppression, and inside a compressed release archive. It also checks that the value never appears in published output. Examples should use environment-variable references, unmistakable placeholders or runtime-generated disposable credentials, never a real development key.

Only metadata reports are retained for one day: rule ID, commit hash, line numbers, and SHA-256 of the relative file path. Matched text, secret values, authors, commit messages, raw scanner output, filenames and full finding fingerprints are omitted. Filenames can contain sensitive values too. Temporary raw reports use scanner redaction and are deleted after scanning. Do not attach raw reports, runtime state or release contents to public issues.

To investigate a reported file hash, run the pinned scanner privately on the same revision/artifacts with `--redact=100 --report-format json` and compare the file's relative-path SHA-256. Keep that local report restricted; do not upload it. A local scanner report can expose filenames and surrounding matched text even when credential values are redacted.

Coverage is detection-based, not proof that a repository is secret-free. Unknown credential formats, encrypted data, compiled/obfuscated values and unsupported archives may not be detected. Archive traversal is bounded to three levels and decoding to five levels; more deeply nested or encrypted packages need separate inspection. Scanner timeouts fail rather than pass. Hostnames, customer details, permissions and dependency licenses require separate review. Scanning neither revokes a credential nor proves it was unused.

## Responding to an exposed credential

1. **Report privately.** Use [GitHub private vulnerability reporting](https://github.com/PIndustries/kiln/security/advisories/new). Record the affected revision or artifact, provider, approximate exposure interval and detection rule. Do not paste the credential, private key, Vault master key, customer data or exploit details into an issue, chat, commit, CI log or this repository.
2. **Contain access immediately.** Pause affected release/distribution jobs and restrict the exposed artifact where possible. Revoke the credential at its issuer before treating removal as remediation. If available, disable the affected account/integration until replacement is ready. In Kiln, revoke compromised SSH identities or adopted peer trust, and revoke unnecessary module Vault grants. Use a trusted administrative session and preserve protected audit evidence.
3. **Rotate through trusted channels.** Create a replacement with the minimum account, resource and operation scope. Store it through Kiln's hidden-input/stdin Vault workflow or the deployment's secret manager. Update only the required module grants and integrations. Never commit the new value, pass it in a public command argument, or put it in an AI prompt. Verify both that authorized operations work and that the old credential is rejected.
4. **Handle encryption-key exposure separately.** Exposure of a Vault master key plus accessible ciphertext compromises the contained credentials. Rotate those upstream credentials; changing a reference alone does not protect old backups. Follow the deployment's approved key/store migration and backup procedure rather than assuming Kiln provides automatic master-key re-encryption. Host/node signing-key replacement requires explicit trust re-enrollment with out-of-band fingerprint verification.
5. **Investigate and preserve evidence.** Review provider access records and Kiln audit/operation receipts for unauthorized activity and uncertain operations. Preserve only necessary evidence in restricted storage, with timestamps and access controls. Do not assume that a failed command, connection timeout or clean scanner result means no action occurred. Assess affected systems/data and coordinate any required notifications privately.
6. **Remove exposure and validate recovery.** Remove the value from the current tree, examples, fixtures, build inputs, artifacts and logs. History cleanup is a coordinated maintainer operation, never an automatic scanner fix: rewriting history does not invalidate copies, forks or caches. Request removal of exposed artifacts/caches through the relevant host where appropriate. Rebuild clean packages, rerun history/tree/artifact scans and the affected integration checks, then restore distribution.
7. **Close with evidence.** Record the issuer-side revocation, replacement validation, exposure scope, remaining uncertainty and follow-up guardrails privately. Publish a sanitized advisory when appropriate. Keep raw secrets out of the public remediation commit and post-incident summary. No response-time SLA is implied.
