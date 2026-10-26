import Foundation
import KilnKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Immutable, atomically committed batches. Incomplete temporary files are never
/// events. A gap, foreign writer or uncertain commit stops work rather than
/// inventing an acknowledgement or replaying a side effect.
struct WorkJournal<Checkpoint: Codable> {
    struct Batch: Codable {
        let schemaVersion: Int
        let worker: String
        let previous: Int
        let events: [AIWorkEvent]
        let checkpoint: Checkpoint?
    }
    private let root: URL
    init(directory: URL) { root = directory.appendingPathComponent("ai-work-events",isDirectory:true) }
    private func checkDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path,&info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw AIError.message("Worker journal requires an owned private directory without symbolic links") }
    }
    private func prepare() throws {
        try checkDirectory(root.deletingLastPathComponent())
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try checkDirectory(root)
    }
    private func folder(_ id: String) throws -> URL {
        guard UUID(uuidString:id) != nil, id == id.lowercased() else { throw AIError.message("Invalid worker journal ID") }
        return root.appendingPathComponent(id,isDirectory:true)
    }
    func ids() throws -> [String] {
        try prepare()
        let children = try FileManager.default.contentsOfDirectory(atPath:root.path).filter { !$0.hasPrefix(".") }
        guard children.count <= 512 else { throw AIError.message("Worker journal retention full; archive finished history before creating more work") }
        for id in children { try checkDirectory(folder(id)) }
        return children.sorted()
    }
    private func files(_ directory: URL) throws -> [URL] {
        try checkDirectory(directory)
        let files = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).filter { !$0.lastPathComponent.hasPrefix(".") }
        guard files.count <= 8192, files.allSatisfy({ $0.pathExtension == "json" && $0.deletingPathExtension().lastPathComponent.count == 20 && $0.deletingPathExtension().lastPathComponent.allSatisfy(\.isNumber) }) else { throw AIError.message("Worker journal has invalid segments or exceeded its segment guard") }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func legacySnapshot() throws -> Data? {
        try prepare()
        let path = root.deletingLastPathComponent().appendingPathComponent("ai-work.json")
        var info = stat()
        if lstat(path.path,&info) != 0 {
            guard errno == ENOENT else { throw AIError.message("Legacy worker history unavailable") }
            return nil
        }
        return try read(path,limit:32_000_000)
    }
    private func read(_ file: URL, limit: Int = 8_388_608) throws -> Data {
        let fd = open(file.path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw AIError.message("Worker journal segment unavailable") }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true); defer { try? handle.close() }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_size >= 0, info.st_size <= limit else { throw AIError.message("Unsafe or oversized worker journal segment") }
        let bytes = try handle.read(upToCount:limit+1) ?? Data()
        guard bytes.count <= limit else { throw AIError.message("Oversized worker journal segment") }
        return bytes
    }
    func batches(_ id: String) throws -> [Batch] {
        try prepare(); let directory = try folder(id)
        guard FileManager.default.fileExists(atPath:directory.path) else { return [] }
        var previous = 0, total = 0, result: [Batch] = []
        for file in try files(directory) {
            let bytes = try read(file); total += bytes.count
            guard total <= 33_554_432 else { throw AIError.message("Worker event history exceeds 32 MiB; inspect and archive it") }
            let batch = try JSONDecoder().decode(Batch.self,from:bytes)
            guard batch.schemaVersion == 1, batch.worker == id, batch.previous == previous, !batch.events.isEmpty else { throw AIError.message("Worker journal sequence gap or identity mismatch; inspect history before retrying") }
            for event in batch.events {
                guard event.sequence == previous+1 else { throw AIError.message("Worker journal event order is invalid") }
                previous = event.sequence
            }
            guard Int(file.deletingPathExtension().lastPathComponent) == previous else { throw AIError.message("Worker journal filename disagrees with its sequence") }
            result.append(batch)
        }
        return result
    }
    @discardableResult func append(_ id: String, after previous: Int, events: [AIWorkEvent], checkpoint: Checkpoint?) throws -> Int {
        try prepare(); let directory = try folder(id)
        let lock = open(root.appendingPathComponent(".writer-lock").path,O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,mode_t(0o600))
        guard lock >= 0 else { throw AIError.message("Worker journal lock unavailable") }
        defer { close(lock) }
        var info = stat()
        guard fstat(lock,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              flock(lock,LOCK_EX | LOCK_NB) == 0 else { throw AIError.message("Worker journal writer busy or unsafe; work stopped before its next tool") }
        defer { _ = flock(lock,LOCK_UN) }
        guard !events.isEmpty, previous >= 0, previous <= Int.max-events.count else { throw AIError.message("Invalid worker journal batch") }
        if !FileManager.default.fileExists(atPath:directory.path) {
            guard try ids().count < 512 else { throw AIError.message("Worker journal retention full") }
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            // Persist creation of this worker's namespace before accepting events.
            let fd = open(root.path,O_RDONLY | O_CLOEXEC); guard fd >= 0 else { throw AIError.message("Cannot open worker journal directory") }
            defer { close(fd) }; guard fsync(fd) == 0 else { throw AIError.message("Cannot flush worker namespace; inspect storage before retrying") }
        }
        let segments = try files(directory)
        let committed = segments.last.flatMap { Int($0.deletingPathExtension().lastPathComponent) } ?? 0
        guard committed == previous else { throw AIError.message("Worker journal changed in another runtime; restart and reconcile before retrying") }
        var ordered = events
        for index in ordered.indices { ordered[index].sequence = previous+index+1 }
        let last = previous+ordered.count
        let bytes = try JSONEncoder().encode(Batch(schemaVersion:1,worker:id,previous:previous,events:ordered,checkpoint:checkpoint))
        let used = try segments.reduce(Int64(0)) { total,file in
            var info = stat(); guard lstat(file.path,&info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw AIError.message("Unsafe worker journal segment") }
            return total+Int64(info.st_size)
        }
        guard bytes.count <= 8_388_608, used+Int64(bytes.count) <= 33_554_432, segments.count < 8192 else { throw AIError.message("Worker event storage guard reached; no further tools will execute. Archive finished history before retrying.") }
        try KilnStateFile.write(bytes,to:directory.appendingPathComponent(String(format:"%020lld.json",Int64(last))))
        return last
    }
}
