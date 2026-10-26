import Foundation

public struct AgentProposalSummary: Codable, Sendable {
    public let worker: String
    public let status: String
    public let created: Date
}
public struct AgentFileReview: Codable, Sendable {
    public let worker: String
    public let status: String
    public let files: [String]
    public let path: String
    public let base: String?
    public let current: String?
    public let proposed: String?
    public let currentSHA256: String
    public let proposalSHA256: String
    public let conflict: Bool
    public let diff: String
    public init(worker: String, status: String, files: [String], path: String, base: String?, current: String?, proposed: String?, currentSHA256: String, proposalSHA256: String, conflict: Bool, diff: String) {
        self.worker = worker; self.status = status; self.files = files; self.path = path
        self.base = base; self.current = current; self.proposed = proposed
        self.currentSHA256 = currentSHA256; self.proposalSHA256 = proposalSHA256; self.conflict = conflict; self.diff = diff
    }
}
