import Foundation

public struct SwiftIDEBuffer: Codable, Sendable, Equatable {
    public let sha256: String
    public let text: String
    public init(sha256: String, text: String) { self.sha256 = sha256; self.text = text }
}
public struct SwiftIDERequest: Codable, Sendable {
    public let action: String
    public let path: String
    public let sha256: String
    public let text: String
    public let cursor: Int
    public let buffers: [String:SwiftIDEBuffer]?
    public let newName: String?
    public var testFilter: String? = nil
    public init(action: String, path: String, sha256: String, text: String, cursor: Int, buffers: [String:SwiftIDEBuffer]? = nil, newName: String? = nil) {
        self.action = action; self.path = path; self.sha256 = sha256; self.text = text; self.cursor = cursor; self.buffers = buffers; self.newName = newName
    }
}
public struct SwiftIDECompletion: Codable, Sendable {
    public let label: String
    public let detail: String
    public let text: String
    public let start: Int
    public let end: Int
    public init(label: String, detail: String, text: String, start: Int, end: Int) {
        self.label = label; self.detail = detail; self.text = text; self.start = start; self.end = end
    }
}
public struct SwiftIDELocation: Codable, Sendable {
    public let path: String
    public let line: Int
    public let column: Int
    public let message: String
    public init(path: String, line: Int, column: Int, message: String = "") {
        self.path = path; self.line = line; self.column = column; self.message = message
    }
}
public struct SwiftIDEResult: Codable, Sendable {
    public var action: String
    public var message: String
    public var completions: [SwiftIDECompletion] = []
    public var locations: [SwiftIDELocation] = []
    public var edits: [SwiftIDEEdit]?
    public var renameFiles: [String:SwiftIDERenameFile]?
    public var sessionID: String?
    public var documentVersion: Int?
    public var codeActions: [SwiftIDECodeAction]?
    public var coverage: String?
    public var tests: [SwiftIDETest]?
    public init(action: String, message: String) { self.action = action; self.message = message }
}
public struct SwiftIDERenameFile: Codable, Sendable {
    public let source: String
    public let sha256: String
    public let text: String
    public init(source: String, sha256: String, text: String) { self.source = source; self.sha256 = sha256; self.text = text }
}
public struct SwiftIDEEdit: Codable, Sendable {
    public let path: String
    public let start: Int
    public let end: Int
    public let text: String
    public let sha256: String
    public init(path: String, start: Int, end: Int, text: String, sha256: String) {
        self.path = path; self.start = start; self.end = end; self.text = text; self.sha256 = sha256
    }
}

public struct SwiftIDECodeAction: Codable, Sendable {
    public let title: String
    public let kind: String
    public let disabledReason: String?
    public let files: [String:SwiftIDERenameFile]?
    public let edits: [SwiftIDEEdit]?
    public init(title: String, kind: String, disabledReason: String? = nil, files: [String:SwiftIDERenameFile]? = nil, edits: [SwiftIDEEdit]? = nil) {
        self.title = title; self.kind = kind; self.disabledReason = disabledReason
        self.files = files; self.edits = edits
    }
}

public struct SwiftIDETest: Codable, Sendable {
    public var id: String
    public var name: String
    public var state: String
    public var location: SwiftIDELocation?
    public var failures: [SwiftIDELocation]
    public init(id: String, name: String, state: String = "discovered", location: SwiftIDELocation? = nil, failures: [SwiftIDELocation] = []) {
        self.id = id; self.name = name; self.state = state; self.location = location; self.failures = failures
    }
}
