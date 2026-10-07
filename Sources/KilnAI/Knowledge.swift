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
    Module manifests: application, name, version, executable (absolute local path), arguments, optional healthURL and ingressPort, optional secrets mapping environment variables to Vault references. The supervisor supplies KILN_APP_NAME, KILN_DATA_DIR, KILN_RELEASE_VERSION and KILN_PORT for managed ingress. Versions use YY.MM.DD.BUILD for Kiln releases.
    Vault uses authenticated encryption and an external master-key file. No secret reveal tool exists. Per-module grants govern startup delivery; running processes retain received values. Same-UID modules are trusted, not sandboxed. AI's credential is a named grant to kiln/ai. Never request or disclose credentials in chat.
    Planned, NOT IMPLEMENTED: clustering/adoption, shared replicated state, custom database, public TLS/ACME, Cloudflare DNS/Tunnel, Resend, independent replacement of SSH/ingress platform processes, Git builds/downloads, native Apple management applications. Do not claim those are available.
    Running is process state, not proof of health. Use health tools for actual checks. There is no automatic crash restart or multi-node failover. macOS runtime is verified; full Linux runtime execution is not yet verified.
    """
}
