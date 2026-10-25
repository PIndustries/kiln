import Foundation
import KilnKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Private, source-only Git object history. Uses plumbing with a clean
/// environment, no worktree, hooks, remotes, credentials or package execution.
struct DevelopmentGit {
    let directory: URL
    func run(_ arguments: [String], input: Data = Data()) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let token = UUID().uuidString
        let stdin = directory.appendingPathComponent(token + ".in"), stdout = directory.appendingPathComponent(token + ".out")
        try KilnStateFile.write(input, to: stdin); try KilnStateFile.write(Data(), to: stdout)
        defer { try? FileManager.default.removeItem(at: stdin); try? FileManager.default.removeItem(at: stdout) }
        let reader = try FileHandle(forReadingFrom: stdin), writer = try FileHandle(forWritingTo: stdout)
        defer { try? reader.close(); try? writer.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--git-dir", directory.appendingPathComponent("source.git").path, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "core.attributesFile=/dev/null", "-c", "commit.gpgsign=false"] + arguments
        process.environment = ["HOME":directory.path,"XDG_CONFIG_HOME":directory.path,"PATH":"/usr/bin:/bin","GIT_CONFIG_NOSYSTEM":"1","GIT_CONFIG_GLOBAL":"/dev/null","GIT_TERMINAL_PROMPT":"0","GIT_AUTHOR_NAME":"Kiln","GIT_AUTHOR_EMAIL":"kiln@localhost","GIT_COMMITTER_NAME":"Kiln","GIT_COMMITTER_EMAIL":"kiln@localhost","LC_ALL":"C"]
        process.currentDirectoryURL = directory; process.standardInput = reader; process.standardOutput = writer; process.standardError = writer
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning {
            let size = (try? FileManager.default.attributesOfItem(atPath: stdout.path)[.size] as? NSNumber)?.intValue ?? 0
            if Date() > deadline || size > 1048576 { process.terminate(); process.waitUntilExit(); throw KilnError.message("Source history exceeded its operation limit") }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard process.terminationStatus == 0 || (arguments.first == "diff" && process.terminationStatus == 1) else { throw KilnError.message("Source Git history operation failed") }
        let bytes = try Data(contentsOf: stdout)
        guard bytes.count <= 1048576 else { throw KilnError.message("Source history output too large") }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    func initialize() throws {
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("source.git/HEAD").path) { _ = try run(["init","--bare","--template="]) }
    }
    func commit(id: String, version: String, files: [String:Data]) throws -> String {
        try initialize()
        let ref = "refs/kiln/changes/" + id
        if let existing = try? run(["rev-parse","--verify",ref + "^{commit}"]), existing.count == 40 { return existing }
        let tree = try tree(files)
        let parent = try? run(["rev-parse","--verify","refs/heads/main"])
        var args = ["commit-tree",tree]
        if let parent, parent.count == 40 { args += ["-p",parent] }
        let commit = try run(args,input:Data("Kiln development change \(id)\nRelease: \(version)\nSource SHA256: \(try WebFiles(files: files).digest)\n".utf8))
        _ = try run(["update-ref",ref,commit]); _ = try run(["update-ref","refs/heads/main",commit])
        return commit
    }
    func tree(_ files: [String:Data]) throws -> String {
        var entries: [String:String] = [:], directories: [String:[String:Data]] = [:]
        for (path, data) in files {
            let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 1 { entries[parts[0]] = "100644 blob " + (try run(["hash-object","-w","--stdin"],input:data)) }
            else { directories[parts[0], default: [:]][parts[1]] = data }
        }
        for (name, contents) in directories { entries[name] = "040000 tree " + (try tree(contents)) }
        let input = entries.keys.sorted().map { entries[$0]! + "\t" + $0 + "\n" }.joined()
        return try run(["mktree"], input: Data(input.utf8))
    }
    func diff(before: [String:Data], after: [String:Data]) throws -> String {
        try initialize()
        let a = try tree(before), b = try tree(after)
        return try run(["diff","--no-ext-diff","--no-textconv","--no-color","--unified=3",a,b])
    }
}
