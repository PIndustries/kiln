import Foundation

/// Controller-produced facts, never model-generated verification.
public struct RecoveryEvidence: Codable, Sendable, Equatable {
    public enum Health: String, Codable, Sendable { case healthy, unhealthy, unconfigured }
    public let module: String
    public let generation: String
    public let processState: String
    public let health: Health
    public let sampledAt: Date
    public init(module: String, generation: String, processState: String, health: Health, sampledAt: Date = Date()) {
        self.module = module; self.generation = generation; self.processState = processState
        self.health = health; self.sampledAt = sampledAt
    }
}

public struct RecoveryReceipt: Sendable {
    public let state: String
    public let generation: String?
    public init(state: String, generation: String?) { self.state = state; self.generation = generation }
}
