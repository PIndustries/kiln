import Foundation
import KilnKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Bounded text-only project snapshots. No manifests, hooks or scripts execute.
struct WebFiles: Equatable {
    var files: [String: Data]
    static let extensions: Set<String> = ["swift", "html", "css", "js", "json", "md", "txt", "svg"]
    static func validPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && path.utf8.count <= 180 && parts.count <= 8 && parts.allSatisfy {
            !$0.isEmpty && !$0.hasPrefix(".") && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) }
        } && extensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
    func validate() throws {
        guard files["App.swift"] != nil, files.count <= 32,
              files.values.reduce(0, { $0 + $1.count }) <= 262144,
              files.allSatisfy({ Self.validPath($0.key) && $0.value.count <= 65536 && String(data: $0.value, encoding: .utf8) != nil }),
              !files.keys.contains(where: { name in files.keys.contains(where: { $0.hasPrefix(name + "/") }) }) else {
            throw KilnError.message("Use App.swift and up to 32 UTF-8 project files (64 KiB each, 256 KiB total); paths must be relative supported text files without hidden components or file/directory conflicts")
        }
    }
    var encoded: Data { get throws { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(files) } }
    var digest: String { get throws { files.count == 1 ? WebIsolation.digest(files["App.swift"]!) : WebIsolation.digest(try encoded) } }
    static func readFile(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw KilnError.message("Project file unavailable or a symbolic link") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(),
              info.st_mode & 0o022 == 0, info.st_size >= 0, info.st_size <= limit else { throw KilnError.message("Web project file is unsafe or oversized") }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw KilnError.message("Web project file exceeded its limit") }
        return data
    }
    static func checkDirectory(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (WebIsolation.canonical(url.path) == url.path || WebIsolation.canonical(url.path) + "/" == url.path), attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o022 == 0 else { throw KilnError.message("Project directories must be owned, private and free of symbolic links: \(url.lastPathComponent)") }
    }
    static func read(_ config: WebProjectConfiguration) throws -> WebFiles {
        guard let root = config.root else { return WebFiles(files: ["App.swift": try readFile(URL(fileURLWithPath: config.source), limit: 65536)]) }
        let base = URL(fileURLWithPath: root)
        try checkDirectory(base)
        var files: [String: Data] = [:], entries = 0
        func walk(_ directory: URL, prefix: String, depth: Int) throws {
            guard depth <= 8 else { throw KilnError.message("Project directory nesting exceeded") }
            try checkDirectory(directory)
            for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                entries += 1
                guard entries <= 128 else { throw KilnError.message("Project entry limit exceeded") }
                let path = prefix + child.lastPathComponent
                let metadata = try FileManager.default.attributesOfItem(atPath: child.path)
                if metadata[.type] as? FileAttributeType == .typeDirectory {
                    guard !child.lastPathComponent.hasPrefix(".") else { throw KilnError.message("Hidden project directories are excluded") }
                    try walk(child, prefix: path + "/", depth: depth + 1)
                } else {
                    guard validPath(path), WebIsolation.canonical(child.path) == child.path else { throw KilnError.message("Unsupported project file or symbolic link") }
                    files[path] = try readFile(child, limit: 65536)
                    guard files.count <= 32, files.values.reduce(0, { $0 + $1.count }) <= 262144 else { throw KilnError.message("Project source limit exceeded") }
                }
            }
        }
        try walk(base, prefix: "", depth: 0)
        let snapshot = WebFiles(files: files); try snapshot.validate(); return snapshot
    }
    func save(at job: URL, before: Bool = false) throws {
        try KilnStateFile.write(try encoded, to: job.appendingPathComponent(before ? "BeforeFiles.json" : "Files.json"))
        try KilnStateFile.write(files["App.swift"]!, to: job.appendingPathComponent(before ? "Before.swift" : "App.swift"))
    }
    static func retained(at job: URL, before: Bool = false) throws -> WebFiles {
        let manifest = job.appendingPathComponent(before ? "BeforeFiles.json" : "Files.json")
        let files: WebFiles
        if FileManager.default.fileExists(atPath: manifest.path) { files = WebFiles(files: try JSONDecoder().decode([String:Data].self, from: readFile(manifest, limit: 400000))) }
        else { files = WebFiles(files: ["App.swift": try readFile(job.appendingPathComponent(before ? "Before.swift" : "App.swift"), limit: 65536)]) }
        try files.validate(); return files
    }
    func writeSources(at root: URL) throws {
        try validate()
        for (path, bytes) in files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try KilnStateFile.write(bytes, to: file)
        }
    }
    func install(_ config: WebProjectConfiguration, expected: WebFiles) throws {
        guard try Self.read(config) == expected else { throw KilnError.message("Source changed independently; project was not overwritten") }
        guard let root = config.root else {
            guard files.count == 1 else { throw KilnError.message("Adding files requires an explicitly registered project root") }
            try KilnStateFile.write(files["App.swift"]!, to: URL(fileURLWithPath: config.source)); return
        }
        #if os(macOS)
        let directory = URL(fileURLWithPath: root), parent = directory.deletingLastPathComponent()
        try Self.checkDirectory(parent)
        let staged = parent.appendingPathComponent(".kiln-swap-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staged) }
        try writeSources(at: staged)
        guard try Self.read(config) == expected else { throw KilnError.message("Source changed while preparing project installation") }
        // Atomic exchange leaves either the old or the entire new codebase at root.
        guard renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, root, UInt32(RENAME_SWAP)) == 0 else { throw KilnError.message("Atomic project installation failed") }
        #else
        throw KilnError.message("Project installation requires macOS isolation")
        #endif
    }
    func applying(_ edits: String, multiFile: Bool) throws -> WebFiles {
        struct Edit: Decodable { let path: String?; let action: String?; let before: String?; let after: String?; let content: String?; let sha256: String? }
        guard edits.utf8.count <= 262144 else { throw KilnError.message("Project edit limit exceeded") }
        let edits = try JSONDecoder().decode([Edit].self, from: Data(edits.utf8))
        guard !edits.isEmpty, edits.count <= 8 else { throw KilnError.message("Use 1–8 file operations") }
        var updated = self
        for edit in edits {
            let path = edit.path ?? "App.swift", action = edit.action ?? "edit"
            guard Self.validPath(path), multiFile || path == "App.swift" else { throw KilnError.message("File is outside the registered source grant") }
            switch action {
            case "create":
                guard multiFile, updated.files[path] == nil, let content = edit.content else { throw KilnError.message("Create requires a new path and content") }
                updated.files[path] = Data(content.utf8)
            case "delete", "replace":
                guard let current = updated.files[path], edit.sha256 == WebIsolation.digest(current) else { throw KilnError.message("File changed since it was read; read it again before replacing or deleting") }
                if action == "delete" { guard multiFile, path != "App.swift" else { throw KilnError.message("The App.swift entry point cannot be deleted") }; updated.files.removeValue(forKey: path) }
                else { guard let content = edit.content else { throw KilnError.message("Replacement content required") }; updated.files[path] = Data(content.utf8) }
            case "edit":
                guard let current = updated.files[path], let text = String(data: current, encoding: .utf8), let before = edit.before, let after = edit.after,
                      !before.isEmpty, before != after, text.components(separatedBy: before).count == 2 else { throw KilnError.message("Each before text must match exactly once in the selected file") }
                updated.files[path] = Data(text.replacingOccurrences(of: before, with: after).utf8)
            default: throw KilnError.message("Unsupported project file operation")
            }
        }
        try updated.validate()
        guard updated != self else { throw KilnError.message("Project operation contains no change") }
        return updated
    }
}
