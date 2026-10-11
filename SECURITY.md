# Security

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/PIndustries/kiln/security/advisories/new) to report a suspected security issue. Do not post exploit details, credentials, or private runtime data in a public issue.

Include the Kiln version or commit, operating system, configuration needed to reproduce the issue, expected behavior, and observed impact. A minimal reproduction using disposable state is best. Remove tokens, private keys, Vault contents, and customer data from logs and attachments.

Maintainers will use the private report to discuss reproduction and remediation. This project does not currently promise a response-time SLA or long-term security maintenance for older releases. Use the latest release and review its operating limits before deployment.

## Security boundaries

- Application modules are trusted executables running under Kiln's OS user. Process isolation contains crashes; it does not prevent a malicious module from accessing that user's files or privileges. Run Kiln under a dedicated account.
- Administrator access can install executables and manage credentials. Treat it as privileged host access. Operator and viewer permissions restrict management operations; they are not an OS sandbox.
- The Vault encrypts stored credentials and checks module grants. Its master key must be kept separately from state backups. A process with access to the key and encrypted store can decrypt them.
- SSH host keys and adopted peer fingerprints establish trust. Verify them before acceptance. Peer adoption grants the documented administrative operations; it is not tenant isolation.
- AI tools pass through Kiln's authorization and approval checks. Prompts and tool results are sent to the configured provider. Do not put credentials into chat.
- Default management and example listeners bind to loopback. Managed TCP ingress is not public TLS termination. Do not assume an exposed listener supplies authentication or encryption beyond its documented protocol.

See [identity permissions](docs/identities.md), [Vault](docs/vault.md), [peer adoption](docs/clustering.md), and [release operating boundaries](docs/release-readiness.md) for details.

## Credential exposure

See the [secret-scanning and credential-incident runbook](docs/credential-incidents.md) for coverage, private reporting, containment, issuer-side revocation, rotation and recovery. Removing a leaked value from a commit does not revoke it.
