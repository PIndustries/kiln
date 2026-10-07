public struct ManagementSnapshot: Sendable {
    public let servers: [ServerSnapshot]
    public let sessions: [TerminalSessionSnapshot]
    public let keys: [String]
    public let error: String?
    public init(servers: [ServerSnapshot] = [], sessions: [TerminalSessionSnapshot] = [], keys: [String] = [], error: String? = nil) {
        self.servers = servers; self.sessions = sessions; self.keys = keys; self.error = error
    }
}
