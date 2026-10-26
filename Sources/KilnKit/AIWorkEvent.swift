import Foundation

/// Ordered controller evidence. Provider prose remains prose; tool intent is
/// distinct from a returned result and is never an instruction to replay it.
public struct AIWorkEvent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case created, migrated, running, interrupted, cancellationRequested, finished, removed
        case contextQueued, contextConsumed
        case answer, reasoning, snapshot, status, source, provider
        case toolStarted, toolReturned
    }
    public var sequence: Int = 0
    public var timestamp: Date = Date()
    public let kind: Kind
    public var text: String?
    public var contextIDs: [String]?
    public var callID: String?
    public var tool: String?
    public var file: AISourcePreview?
    public var provider: AIProviderSnapshot?
    public init(_ kind: Kind, text: String? = nil, contextIDs: [String]? = nil, callID: String? = nil, tool: String? = nil) {
        self.kind = kind; self.text = text; self.contextIDs = contextIDs; self.callID = callID; self.tool = tool
    }
}
