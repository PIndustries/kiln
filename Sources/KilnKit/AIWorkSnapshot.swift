import Foundation

/// A controller-owned snapshot of background work, independent of a terminal.
public struct AISourcePreview: Codable, Sendable {
    public let module: String
    public let path: String
    public let source: String
    public let draft: Bool
    public init(module: String, path: String, source: String, draft: Bool) {
        self.module = module; self.path = path; self.source = source; self.draft = draft
    }
}
public struct AIWorkSnapshot: Codable, Sendable {
    public let id: String
    public let prompt: String
    public var state: String
    public var answer = ""
    public var reasoning = ""
    public var activity = ""
    public var file: AISourcePreview?
    public var provider: AIProviderSnapshot?
    public var contextMessages: [String]?
    public var queuedContext = 0
    public init(id: String, prompt: String, state: String) { self.id = id; self.prompt = prompt; self.state = state }
    public var active: Bool { ["queued","running","cancelling"].contains(state) }
}
