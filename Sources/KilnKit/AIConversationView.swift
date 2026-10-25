import Foundation

public struct AIConversationEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case request, answer, notice, operation, reasoning }
    public let cursor: UInt64
    public let kind: Kind
    public let text: String
    public let source: AIProviderSnapshot?
    public let timestamp: Date
    public init(cursor: UInt64, kind: Kind, text: String, source: AIProviderSnapshot? = nil, timestamp: Date = Date()) {
        self.cursor = cursor; self.kind = kind; self.text = text; self.source = source; self.timestamp = timestamp
    }
}
public struct AIConversationView: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let name: String?
    public let id: String?
    public let events: [AIConversationEvent]
    public let oldestCursor: UInt64
    public let latestCursor: UInt64
    public let gap: Bool
    public let notice: String
    public let expiresAt: Date?
    public init(name: String?, id: String? = nil, events: [AIConversationEvent], oldestCursor: UInt64 = 0, latestCursor: UInt64 = 0, gap: Bool = false, notice: String = "", expiresAt: Date? = nil) {
        self.schemaVersion = 1; self.name = name; self.id = id; self.events = events; self.oldestCursor = oldestCursor; self.latestCursor = latestCursor; self.gap = gap; self.notice = notice; self.expiresAt = expiresAt
    }
}
