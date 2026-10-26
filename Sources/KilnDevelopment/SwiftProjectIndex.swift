import Foundation
import KilnKit
import KilnIndexBridge
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct SwiftIndexOccurrence: Sendable, Hashable {
    let path: String
    let usr: String
    let name: String
    let kind: UInt32
    let line: Int
    let utf8Column: Int
    let roles: UInt64
}
private final class IndexCollector {
    let root: String
    let allowed: Set<String>
    var rows = Set<SwiftIndexOccurrence>()
    var bytes = 0
    var cancelled = false
    init(root: String, allowed: Set<String>) { self.root = root; self.allowed = allowed }
}

/// Compiler-produced symbol identities and occurrences, without a third-party
/// database or textual guesses about overloads. Index artifacts stay private and
/// are discarded after the bounded, deduplicated records have been read.
enum SwiftProjectIndex {
    private static func identifier(_ char: Character) -> Bool { char.isLetter || char.isNumber || char == "_" }
    static func token(in text: String, at cursor: Int) -> (start: Int, end: Int, name: String)? {
        let chars = Array(text)
        guard !chars.isEmpty, (0...chars.count).contains(cursor) else { return nil }
        var point = min(cursor,chars.count-1)
        if !identifier(chars[point]), chars[point] != "`", point > 0, identifier(chars[point-1]) { point -= 1 }
        if chars[point] == "`", point+1 < chars.count, identifier(chars[point+1]) { point += 1 }
        guard identifier(chars[point]) else { return nil }
        var start = point, end = point+1
        while start > 0 && identifier(chars[start-1]) { start -= 1 }
        while end < chars.count && identifier(chars[end]) { end += 1 }
        let name = String(chars[start..<end])
        if start > 0 && end < chars.count && chars[start-1] == "`" && chars[end] == "`" { start -= 1; end += 1 }
        return (start,end,name)
    }
    static func response(rows: [SwiftIndexOccurrence], files: [String:String], root: URL, selected: String, cursor: Int, action: String, newName: String?) throws -> [String:Any]? {
        guard let source = files[selected], let selectedToken = token(in:source,at:cursor) else { return nil }
        func baseName(_ name: String) -> String { String(name.prefix { $0 != "(" && $0 != ":" }) }
        let selectedRows = rows.filter { row in
            guard row.path == selected, row.roles & 7 != 0, row.roles & (1 << 8) == 0, baseName(row.name) == selectedToken.name,
                  let location = position(row,text:source), let symbolToken = token(in:source,at:location.offset) else { return false }
            return symbolToken.start == selectedToken.start && symbolToken.end == selectedToken.end
        }
        let identities = Set(selectedRows.map(\.usr).filter { !$0.isEmpty })
        guard !identities.isEmpty else { return nil }
        let occurrences = rows.filter { identities.contains($0.usr) && $0.roles & 7 != 0 && $0.roles & (1 << 8) == 0 }
        if action == "rename" {
            guard let newName, newName != "_", occurrences.contains(where: { $0.path.hasPrefix("Sources/") && $0.roles & 3 != 0 }) else { throw KilnError.message("Only declared project symbols can be renamed; SDK and generated definitions are outside the edit grant") }
            guard !occurrences.contains(where: { !$0.path.hasPrefix("Sources/") || $0.roles & (1 << 11) != 0 }) else { throw KilnError.message("This rename crosses generated code or an override relationship; use an explicit refactor instead") }
        }
        var locations: [[String:Any]] = [], changes: [String:[[String:Any]]] = [:], seen = Set<String>()
        for row in occurrences {
            guard let text = files[row.path], let location = position(row,text:text), let name = token(in:text,at:location.offset) else { throw KilnError.message("Compiler index location does not match its source snapshot") }
            let key = row.path+":"+String(name.start)+":"+String(name.end)
            guard seen.insert(key).inserted else { continue }
            let uri = root.appendingPathComponent(row.path).absoluteString
            let before = String(text.prefix(name.start)), startLine = before.filter { $0 == "\n" }.count
            let startColumn = before.components(separatedBy:"\n").last!.utf16.count
            let length = String(text.dropFirst(name.start).prefix(name.end-name.start)).utf16.count
            let range: [String:Any] = ["start":["line":startLine,"character":startColumn],"end":["line":startLine,"character":startColumn+length]]
            if action == "rename" {
                if ["Self","self"].contains(name.name), name.name != selectedToken.name { continue }
                guard name.name == selectedToken.name else { throw KilnError.message("A compiler reference uses unsupported spelling; no partial rename was proposed") }
                changes[uri,default:[]].append(["range":range,"newText":newName!])
            } else { locations.append(["uri":uri,"range":range]) }
        }
        return ["value":action == "rename" ? ["changes":changes] as Any : locations as Any,"coverage":"project"]
    }
    static func build(sdk: WebBuildSDK, root: URL, files: [String:String]) async throws -> [SwiftIndexOccurrence] {
        try Task.checkCancellation()
        let job = root.appendingPathComponent("index-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:job,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:job) }
        let log = job.appendingPathComponent("compiler.log"), store = job.appendingPathComponent("store")
        // Distinct object outputs give every primary file a distinct index unit.
        // A multi-file -typecheck invocation otherwise reuses the '-' output unit
        // and leaves only its last primary file visible to IndexStore readers.
        let outputMap = Dictionary(uniqueKeysWithValues:files.keys.sorted().enumerated().map { index,path in
            (root.appendingPathComponent(path).path,["object":job.appendingPathComponent("unit-\(index).o").path])
        })
        let map = job.appendingPathComponent("outputs.json")
        try KilnStateFile.write(JSONEncoder().encode(outputMap),to:map)
        var arguments = ["/usr/bin/sandbox-exec","-p",WebIsolation.buildProfile(sdk:sdk,job:root.path),sdk.compiler] + sdk.arguments
        arguments += ["-emit-object","-j","1","-output-file-map",map.path,"-module-cache-path",root.appendingPathComponent("cache").path,"-index-store-path",store.path,"-index-ignore-system-modules","-index-ignore-clang-modules","-index-include-locals"] + files.keys.sorted().map { root.appendingPathComponent($0).path }
        let environment = ["HOME="+root.path,"TMPDIR="+root.path+"/","PATH=/usr/bin:/bin","LANG=en_US.UTF-8"]
        var argv = arguments.map { strdup($0) }+[nil], env = environment.map { strdup($0) }+[nil]
        defer { for value in argv { free(value) }; for value in env { free(value) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), env.dropLast().allSatisfy({ $0 != nil }) else { throw KilnError.message("Cannot allocate compiler arguments") }
        var pid: Int32 = 0
        let spawned = argv.withUnsafeMutableBufferPointer { args in env.withUnsafeMutableBufferPointer { vars in
            kiln_index_spawn(arguments[0],args.baseAddress,vars.baseAddress,root.path,log.path,&pid)
        } }
        guard spawned == 0, pid > 0 else { throw KilnError.message("Cannot start isolated Swift indexing compiler") }
        var reaped = false
        defer {
            if !reaped {
                _ = kill(-pid,SIGKILL); _ = kill(pid,SIGKILL)
                let end = Date().addingTimeInterval(2)
                var ignored: Int32 = 0
                while Date() < end {
                    if kiln_index_poll(pid,&ignored) != 0 { break }
                    usleep(10000)
                }
            }
        }
        let deadline = ContinuousClock.now.advanced(by:.seconds(30))
        var status: Int32 = 0
        while true {
            try Task.checkCancellation()
            let logSize = (try? FileManager.default.attributesOfItem(atPath:log.path)[.size] as? NSNumber)?.intValue ?? 0
            guard ContinuousClock.now < deadline, logSize <= 65536 else { throw KilnError.message("Swift indexing exceeded its time or diagnostic guard") }
            let result = kiln_index_poll(pid,&status)
            guard result >= 0 else { throw KilnError.message("Swift indexing process status unavailable") }
            if result == 1 { reaped = true; break }
            try await Task.sleep(for:.milliseconds(20))
        }
        guard status == 0 else {
            let diagnostic = String(decoding:(try? WebFiles.readFile(log,limit:65536)) ?? Data(),as:UTF8.self)
            throw KilnError.message("Project indexing compiler failed; no partial project results were used.\n"+String(diagnostic.prefix(4000)))
        }
        let library = URL(fileURLWithPath:sdk.compiler).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/libIndexStore.dylib")
        return try read(library:library,store:store,root:root,allowed:Set(files.keys))
    }
    static func read(library: URL, store: URL, root: URL, allowed: Set<String>) throws -> [SwiftIndexOccurrence] {
        let prefix = WebIsolation.canonical(root.path)+"/"
        let collector = IndexCollector(root:prefix,allowed:allowed)
        let result = kiln_index_read(library.path,store.path,prefix,Unmanaged.passUnretained(collector).toOpaque()) { context,file,usr,name,kind,line,column,roles in
            guard let context, let file, let usr, let name else { return 0 }
            let state = Unmanaged<IndexCollector>.fromOpaque(context).takeUnretainedValue()
            if Task.isCancelled { state.cancelled = true; return 0 }
            let absolute = WebIsolation.canonical(String(cString:file))
            guard absolute.hasPrefix(state.root) else { return 1 }
            let path = String(absolute.dropFirst(state.root.count))
            guard state.allowed.contains(path), line > 0, column > 0 else { return 1 }
            let row = SwiftIndexOccurrence(path:path,usr:String(cString:usr),name:String(cString:name),kind:kind,line:Int(line),utf8Column:Int(column),roles:roles)
            if state.rows.contains(row) { return 1 }
            state.bytes += path.utf8.count+row.usr.utf8.count+row.name.utf8.count+128
            guard state.rows.count < 100000, state.bytes <= 16_777_216 else { return 0 }
            state.rows.insert(row); return 1
        }
        if collector.cancelled { throw CancellationError() }
        guard result == 0 else { throw KilnError.message("Compiler index unavailable, invalid or beyond its record guard (\(result)); no partial project results were used") }
        return collector.rows.sorted { ($0.path,$0.line,$0.utf8Column,$0.usr) < ($1.path,$1.line,$1.utf8Column,$1.usr) }
    }
    /// IndexStore columns count UTF-8 bytes. Editor/LSP columns count UTF-16 units.
    static func position(_ occurrence: SwiftIndexOccurrence, text: String) -> (offset: Int, line: Int, column: Int)? {
        let rows = text.components(separatedBy:"\n"), line = occurrence.line-1
        guard rows.indices.contains(line), occurrence.utf8Column > 0, occurrence.utf8Column-1 <= rows[line].utf8.count,
              let index = String.Index(rows[line].utf8.index(rows[line].utf8.startIndex,offsetBy:occurrence.utf8Column-1),within:rows[line]) else { return nil }
        let offset = rows.prefix(line).reduce(0) { $0+$1.count+1 }+rows[line].distance(from:rows[line].startIndex,to:index)
        return (offset,line,rows[line][..<index].utf16.count)
    }
}
