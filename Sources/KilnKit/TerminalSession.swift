public struct TerminalSessionSnapshot: Sendable {
    public let name: String
    public let server: String
    public let state: String
    public let attached: Bool
    public init(name: String, server: String, state: String, attached: Bool) {
        self.name = name; self.server = server; self.state = state; self.attached = attached
    }
}
