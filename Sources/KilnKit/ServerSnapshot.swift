public struct ServerSnapshot: Codable, Sendable {
    public let name: String
    public let host: String
    public let user: String
    public let port: Int
    public let key: String?
    public let fingerprint: String?
    public let candidate: String?
    public init(name: String, host: String, user: String, port: Int, key: String?, fingerprint: String?, candidate: String?) {
        self.name = name; self.host = host; self.user = user; self.port = port
        self.key = key; self.fingerprint = fingerprint; self.candidate = candidate
    }
}
