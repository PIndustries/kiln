import Foundation

/// Typed presentation data only. Actions still pass through normal command
/// authorization and the assistant's session-bound, single-use approval gate.
public struct AIProposalSnapshot: Sendable, Equatable {
    public let id: String
    public let operation: String
    public let module: String
    public let expires: Date
    public init(id: String, operation: String, module: String, expires: Date) {
        self.id = id; self.operation = operation; self.module = module; self.expires = expires
    }
}
public struct AITaskSnapshot: Sendable, Equatable {
    public let id: String
    public let prompt: String
    public let status: String
    public init(id: String, prompt: String, status: String) { self.id = id; self.prompt = prompt; self.status = status }
}
public struct AIWorkspaceSnapshot: Sendable, Equatable {
    public let proposals: [AIProposalSnapshot]
    public let tasks: [AITaskSnapshot]
    public let error: String?
    public init(proposals: [AIProposalSnapshot] = [], tasks: [AITaskSnapshot] = [], error: String? = nil) {
        self.proposals = proposals; self.tasks = tasks; self.error = error
    }
}
