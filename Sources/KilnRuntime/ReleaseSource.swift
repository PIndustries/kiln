import Foundation
import Crypto
import KilnKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct ReleaseSource: Sendable {
    let manifest: ApplicationManifest
    let bundle: ApplicationBundleManifest?
    let root: URL?
    static func load(_ path: String) throws -> ReleaseSource {
        let url = URL(fileURLWithPath: path)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else { throw KilnError.message("Application source is missing") }
        if !directory.boolValue {
            let manifest = try JSONDecoder().decode(ApplicationManifest.self, from: Data(contentsOf: url))
            try manifest.validate()
            return ReleaseSource(manifest: manifest, bundle: nil, root: nil)
        }
        try requireKind(url, directory: true)
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appendingPathComponent("bundle.json")
        try requireKind(file, directory: false)
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw KilnError.message("Cannot open bundle manifest") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw KilnError.message("Bundle manifest must be a regular file") }
        let data = try handle.read(upToCount: 2_097_153) ?? Data()
        guard data.count <= 2_097_152 else { throw KilnError.message("Bundle manifest exceeds 2 MiB") }
        let moduleKeys: Set<String> = ["application", "name", "version", "executable", "arguments", "healthURL", "ingressPort", "secrets", "restartPolicy", "resources"]
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["formatVersion", "platform", "module", "files"]),
              let module = object["module"] as? [String: Any], Set(module.keys).isSubset(of: moduleKeys),
              let files = object["files"] as? [[String: Any]], files.allSatisfy({ Set($0.keys).isSubset(of: ["path", "sha256", "executable"]) }) else {
            throw KilnError.message("Unsupported bundle manifest fields")
        }
        let bundle = try JSONDecoder().decode(ApplicationBundleManifest.self, from: data)
        return ReleaseSource(manifest: try bundle.installedManifest(in: root), bundle: bundle, root: root)
    }
    static func requireKind(_ url: URL, directory: Bool) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(directory ? S_IFDIR : S_IFREG) else {
            throw KilnError.message("Bundle entries must be regular files/directories, without symbolic links")
        }
    }
    static func fileURL(_ path: String, in root: URL) throws -> URL {
        try ApplicationBundleManifest.validatePath(path)
        try requireKind(root, directory: true)
        var url = root
        let parts = path.split(separator: "/")
        for (index, part) in parts.enumerated() {
            url.appendPathComponent(String(part))
            try requireKind(url, directory: index < parts.count - 1)
        }
        return url
    }
    /// Stream data with per-file/total limits; never load an entire application
    /// into memory. The copied bytes, rather than a prior source-file check, are hashed.
    static func digestFile(_ url: URL, copyingTo destination: URL? = nil, total: inout Int) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw KilnError.message("Cannot open bundle file") }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size <= 268_435_456 else { throw KilnError.message("Bundle file is not regular or exceeds 256 MiB") }
        var output: FileHandle?
        if let destination {
            let out = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard out >= 0 else { throw KilnError.message("Cannot create bundle release file") }
            output = FileHandle(fileDescriptor: out, closeOnDealloc: true)
        }
        defer { try? output?.close() }
        var hash = SHA256(), count = 0
        while let bytes = try input.read(upToCount: 65_536), !bytes.isEmpty {
            count += bytes.count; total += bytes.count
            guard count <= 268_435_456, total <= 536_870_912 else { throw KilnError.message("Bundle exceeds file/total size limits") }
            hash.update(data: bytes); try output?.write(contentsOf: bytes)
        }
        try output?.synchronize()
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func copyBundle(to destination: URL) throws {
        guard let bundle, let root else { throw KilnError.message("Missing bundle payload") }
        var total = 0, directories = Set<URL>()
        for file in bundle.files {
            let source = try Self.fileURL(file.path, in: root)
            let target = destination.appendingPathComponent(file.path), parent = target.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let parts = file.path.split(separator: "/")
            for depth in 1..<parts.count {
                directories.insert(destination.appendingPathComponent(parts.prefix(depth).joined(separator: "/")))
            }
            guard try Self.digestFile(source, copyingTo: target, total: &total) == file.sha256 else { throw KilnError.message("Bundle checksum mismatch: " + file.path) }
            try FileManager.default.setAttributes([.posixPermissions: file.executable ? 0o500 : 0o400], ofItemAtPath: target.path)
            try Self.sync(target)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try KilnStateFile.write(encoder.encode(bundle), to: destination.appendingPathComponent("bundle.json"))
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) { try Self.sync(directory) }
    }
    static func sync(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw KilnError.message("Cannot open bundle release for persistence") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw KilnError.message("Cannot flush bundle release") }
    }
    static func verify(_ bundle: ApplicationBundleManifest, manifest: ApplicationManifest, root: URL) throws {
        let expected = try bundle.installedManifest(in: root)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let disk = try load(root.path).bundle, try encoder.encode(disk) == encoder.encode(bundle) else { throw KilnError.message("Installed bundle manifest integrity check failed") }
        guard try encoder.encode(expected) == encoder.encode(manifest) else { throw KilnError.message("Bundle release metadata does not match its application") }
        var total = 0
        for file in bundle.files {
            let url = try fileURL(file.path, in: root)
            guard try digestFile(url, total: &total) == file.sha256,
                  !file.executable || FileManager.default.isExecutableFile(atPath: url.path) else { throw KilnError.message("Installed bundle integrity check failed: " + file.path) }
        }
    }
    static func identity(_ bundle: ApplicationBundleManifest) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(bundle)).map { String(format: "%02x", $0) }.joined()
    }
}
