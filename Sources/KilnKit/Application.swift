import Foundation

/// A release contract, independent of its management interface or application protocols.
public struct ApplicationManifest: Codable, Sendable {
    public let application: String
    public let name: String
    public let version: String
    public var executable: String
    public let arguments: [String]
    public let healthURL: String?

    public init(application: String = "default", name: String, version: String, executable: String, arguments: [String] = [], healthURL: String? = nil) {
        self.application = application; self.name = name; self.version = version; self.executable = executable
        self.arguments = arguments; self.healthURL = healthURL
    }

    public func validate() throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        for value in [application, name, version] {
            guard !value.isEmpty, value.count <= 80, value != ".", value != "..",
                  value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                throw KilnError.message("Invalid application name or version")
            }
        }
        guard executable.hasPrefix("/") else { throw KilnError.message("Executable must be an absolute path") }
        if let healthURL {
            guard let url = URL(string: healthURL), url.scheme == "http", url.host == "127.0.0.1" else {
                throw KilnError.message("Prototype health checks must use http://127.0.0.1")
            }
        }
    }
}

public enum KilnError: Error, CustomStringConvertible {
    case message(String)
    public var description: String { switch self { case .message(let text): return text } }
}

/// Transport-independent observation; process state does not imply application health.
public struct ModuleSnapshot: Sendable, Equatable {
    public let application: String
    public let name: String
    public let version: String
    public let state: String
    public let pid: Int32?
    public var id: String { "\(application)/\(name)" }
    public init(application: String, name: String, version: String, state: String, pid: Int32?) {
        self.application = application; self.name = name; self.version = version
        self.state = state; self.pid = pid
    }
}
