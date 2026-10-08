import Foundation

public struct AIKnowledgePack: Codable, Sendable {
    public let version: String
    public let notes: String
    public func validate() throws {
        guard version.range(of: "^[A-Za-z0-9._-]{1,80}$", options: .regularExpression) != nil,
              !notes.isEmpty, notes.utf8.count <= 24576 else { throw AIError.message("Knowledge pack requires a version and 1-24576 bytes of notes") }
    }
    public static let foundation = """
    Kiln is a modular native Swift application platform by P.Industries. This is a single-node development runtime.
    Deployed application modules are separate trusted OS processes identified by application/module. Swift framework targets remain linked into the host executable.
    Available: optional public-key SSH, native TUI, persistent remote terminal service, bastion destinations, host metrics, local executable manifests, start/stop/restart, HTTP readiness, loopback TCP ingress, draining, rollback, encrypted Vault and per-module startup grants.
    A managed release stages an executable, starts a candidate on a distinct worker port, requires three HTTP 200 health probes, persists active/previous manifests, switches new TCP connections, drains old connections for up to 30 seconds and stops the old worker. Existing WebSockets do not migrate; clients need reconnect after forced drain. Rollback restores code, not database writes. Legacy app restart interrupts that app. Supervisor restart interrupts app traffic. Remote terminals live in a separate service and survive a dashboard restart while that service remains alive.
    Module manifests: application, name, version, executable (absolute local path), arguments, optional healthURL and ingressPort, optional secrets mapping environment variables to Vault references, optional restartPolicy (never or always). The supervisor supplies KILN_APP_NAME, KILN_DATA_DIR, KILN_RELEASE_VERSION and KILN_PORT for managed ingress. Versions use YY.MM.DD.BUILD for Kiln releases.
    Vault uses authenticated encryption and an external master-key file. No secret reveal tool exists. Per-module grants govern startup delivery; running processes retain received values. Same-UID modules are trusted, not sandboxed. AI's credential is a named grant to kiln/ai. Never request or disclose credentials in chat.
    Planned, NOT IMPLEMENTED: clustering/adoption, shared replicated state, custom database, public TLS/ACME, Cloudflare DNS/Tunnel, Resend, independent replacement of SSH/ingress platform processes, Git builds/downloads, native Apple management applications. Do not claim those are available.
    Running is process state, not proof of health. Use health tools for actual checks. restartPolicy always enables three automatic retries with 1/2/4-second backoff; 60 seconds of continuous process uptime resets the budget. It does not prove health. Explicit start resets the budget; stop disables recovery. Omitted policies require manual restart. AI operations have persistent outcome receipts (ai operations); unconfirmed outcomes must be inspected and must not be blindly retried. Approvals remain session-bound and in memory. Direct workers have guardians that terminate them if the supervisor dies; startup reconciles ownership before reopening SSH and restores the committed active release. This interrupts ingress connections, does not migrate them, and does not contain daemonized descendants or guardian SIGKILL. Interrupted background tasks are not replayed; unfinished operation receipts remain unconfirmed. There is no multi-node failover. macOS arm64 and Linux x86_64 (Swift 6.2.3 container) passed release tests and SSH/REST/WebSocket runtime integration. This does not establish production deployment, every Linux distribution, or multi-node behavior.
    """
}
