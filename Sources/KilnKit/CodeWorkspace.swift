import Foundation

/// Editor recovery data, separate from published application source.
public struct CodeWorkspaceBuffer: Codable, Equatable, Sendable {
    public var source: String
    public var draft: String
    public var sha256: String
    public var cursor: Int
    public var offset: Int
    public var horizontal: Int
    public var isNew: Bool
    public init(source: String, draft: String, sha256: String, cursor: Int, offset: Int, horizontal: Int, isNew: Bool) {
        self.source = source; self.draft = draft; self.sha256 = sha256; self.cursor = cursor
        self.offset = offset; self.horizontal = horizontal; self.isNew = isNew
    }
}
public struct CodeWorkspaceState: Codable, Equatable, Sendable {
    public var path = "App.swift"
    public var cursor = 0
    public var offset = 0
    public var horizontal = 0
    public var wrapping = false
    public var vim = false
    public var treeFocus = true
    public var dividerShare = 6000
    public var buffers: [String:CodeWorkspaceBuffer] = [:]
    public init() {}
}
public struct CodeWorkspaceRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let module: String
    public var revision: Int
    public var state: CodeWorkspaceState
    public init(module: String) {
        self.schemaVersion = 1; self.id = UUID().uuidString.lowercased(); self.module = module
        self.revision = 0; self.state = CodeWorkspaceState()
    }
}
public struct CodeWorkspaceSave: Codable, Sendable {
    public let expectedRevision: Int
    public let state: CodeWorkspaceState
    public init(expectedRevision: Int, state: CodeWorkspaceState) { self.expectedRevision = expectedRevision; self.state = state }
}
