import Foundation

/// Relocatable payload for one declared OS/architecture. Digests establish
/// integrity, not publisher identity or a hostile-code sandbox.
public struct ApplicationBundleManifest: Codable, Sendable {
    public struct File: Codable, Sendable {
        public let path: String
        public let sha256: String
        public let executable: Bool
        public init(path: String, sha256: String, executable: Bool = false) {
            self.path = path; self.sha256 = sha256; self.executable = executable
        }
    }
    public let formatVersion: Int
    public let platform: String
    public let module: ApplicationManifest
    public let files: [File]
    public init(platform: String, module: ApplicationManifest, files: [File]) {
        formatVersion = 1; self.platform = platform; self.module = module; self.files = files
    }
    public static var hostPlatform: String {
        #if os(macOS) && arch(arm64)
        "macos-arm64"
        #elseif os(Linux) && arch(x86_64)
        "linux-x86_64"
        #else
        "unsupported"
        #endif
    }
    public static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 1024, parts.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.count <= 255 &&
            $0.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }
        }) else { throw KilnError.message("Bundle paths must be relative portable ASCII paths without traversal") }
    }
    public func validate(forPlatform host: String? = nil) throws {
        guard formatVersion == 1 else { throw KilnError.message("Unsupported application bundle format") }
        guard ["macos-arm64", "linux-x86_64"].contains(platform), host == nil || host == platform else {
            throw KilnError.message("Application bundle target does not match this host")
        }
        guard !files.isEmpty, files.count <= 4096 else { throw KilnError.message("Bundle requires 1–4096 declared files") }
        try Self.validatePath(module.executable)
        var paths = Set<String>(), prefixes: [String: String] = [:]
        for file in files {
            try Self.validatePath(file.path)
            guard file.path.split(separator: "/").first?.lowercased() != "bundle.json", paths.insert(file.path).inserted,
                  file.sha256.count == 64, file.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw KilnError.message("Invalid or duplicate bundle file/digest")
            }
            let components = file.path.split(separator: "/")
            for depth in 1...components.count {
                let prefix = components.prefix(depth).joined(separator: "/"), key = prefix.lowercased()
                guard prefixes[key] == nil || prefixes[key] == prefix else { throw KilnError.message("Bundle paths collide on case-insensitive filesystems") }
                prefixes[key] = prefix
            }
        }
        for file in files {
            let components = file.path.split(separator: "/")
            for depth in 1..<components.count where paths.contains(components.prefix(depth).joined(separator: "/")) {
                throw KilnError.message("A bundle file cannot also be a directory")
            }
        }
        guard files.contains(where: { $0.path == module.executable && $0.executable }) else { throw KilnError.message("Bundle entrypoint must be a declared executable file") }
        var normalized = module; normalized.executable = "/bundle/" + module.executable
        try normalized.validate()
    }
    public func installedManifest(in directory: URL) throws -> ApplicationManifest {
        try validate(forPlatform: Self.hostPlatform)
        var manifest = module
        manifest.executable = directory.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(module.executable).path
        try manifest.validate()
        return manifest
    }
}
