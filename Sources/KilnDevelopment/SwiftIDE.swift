import Foundation
import KilnKit

extension WebDevelopment {
    public func ide(module: String, request: SwiftIDERequest) async throws -> SwiftIDEResult {
        guard WebIsolation.supported, ideRequests < 4, ["complete","definition","build"].contains(request.action),
              WebFiles.validPath(request.path), (request.path.hasSuffix(".swift") || request.action == "build"), request.text.utf8.count <= 65536,
              (0...request.text.count).contains(request.cursor) else { throw KilnError.message("Invalid Swift IDE request or language service busy") }
        let registered = try project(module)
        var snapshot = try WebFiles.read(registered.configuration)
        if let current = snapshot.files[request.path] {
            guard WebIsolation.digest(current) == request.sha256 else { throw KilnError.message("File changed on disk; reload it before using Swift tools") }
        } else {
            guard registered.configuration.root != nil, request.sha256.isEmpty else { throw KilnError.message("New Swift files require a registered project root") }
        }
        guard (request.buffers?.count ?? 0) <= 32 else { throw KilnError.message("Too many editor buffers") }
        for (path,buffer) in request.buffers ?? [:] {
            guard WebFiles.validPath(path), buffer.text.utf8.count <= 65536 else { throw KilnError.message("Invalid editor buffer") }
            if let original = snapshot.files[path] {
                guard WebIsolation.digest(original) == buffer.sha256 else { throw KilnError.message("An open buffer changed on disk; reload before building") }
            } else { guard registered.configuration.root != nil, buffer.sha256.isEmpty else { throw KilnError.message("Invalid new editor buffer") } }
            snapshot.files[path] = Data(buffer.text.utf8)
        }
        try registered.sdk.verifyInputs()
        snapshot.files[request.path] = Data(request.text.utf8); try snapshot.validate()
        let root = directory.appendingPathComponent("ide/"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        ideRequests += 1
        defer { ideRequests -= 1; try? FileManager.default.removeItem(at:root) }
        try snapshot.writeSources(at:root.appendingPathComponent("Sources"))
        if request.action == "build" {
            try snapshot.save(at:root)
            try KilnStateFile.write(JSONEncoder().encode(registered.sdk),to:root.appendingPathComponent("sdk.json"))
            var passed = true
            do { try await compile(sdk:registered.sdk,job:root) }
            catch is CancellationError { throw CancellationError() }
            catch { passed = false }
            let log = (try? String(contentsOf:root.appendingPathComponent("build.log"),encoding:.utf8)) ?? "No compiler diagnostics available"
            var result = SwiftIDEResult(action:"build",message:passed ? "Build passed. This draft was compiled in isolation; running release unchanged." : "Build failed. Draft and running release preserved.\n"+String(log.prefix(16000)))
            let regex = try NSRegularExpression(pattern:"^(.+\\.swift):(\\d+):(\\d+): (error|warning|note): (.+)$",options:.anchorsMatchLines)
            let prefix = WebIsolation.canonical(root.appendingPathComponent("Sources").path)+"/"
            for match in regex.matches(in:log,range:NSRange(log.startIndex...,in:log)).prefix(64) {
                func group(_ n: Int) -> String { Range(match.range(at:n),in:log).map { String(log[$0]) } ?? "" }
                let absolute = WebIsolation.canonical(group(1)), path = String(absolute.dropFirst(prefix.count))
                guard absolute.hasPrefix(prefix), snapshot.files[path] != nil, let line = Int(group(2)), let column = Int(group(3)) else { continue }
                result.locations.append(SwiftIDELocation(path:path,line:line,column:column,message:group(4)+": "+group(5)))
            }
            return result
        }
        let swiftPaths = snapshot.files.keys.filter { $0.hasSuffix(".swift") }.sorted()
        _ = try WebTemplateCompiler.write(snapshot.files,at:root)
        let reply = try await SwiftLanguage(sdk:registered.sdk,root:root,paths:swiftPaths,source:request.text,selected:request.path).query(action:request.action,cursor:request.cursor)
        let raw = (try JSONSerialization.jsonObject(with:reply) as? [String:Any])?["value"]
        var result = SwiftIDEResult(action:request.action,message:"SourceKit-LSP")
        if request.action == "complete" {
            let items = (raw as? [String:Any])?["items"] as? [[String:Any]] ?? raw as? [[String:Any]] ?? []
            // SourceKit may return an unfiltered list. Filter before limiting it,
            // otherwise common matches can fall beyond the first page of symbols.
            let typedPrefix = String(request.text.prefix(request.cursor).reversed().prefix {
                $0.isLetter || $0.isNumber || $0 == "_"
            }.reversed())
            let prefix = typedPrefix.lowercased()
            let matches = items.filter { item in
                guard !prefix.isEmpty else { return true }
                let name = item["filterText"] as? String ?? item["label"] as? String ?? ""
                return name.lowercased().hasPrefix(prefix)
            }
            let ranked = matches.enumerated().sorted { lhs, rhs in
                func exactCase(_ item: [String:Any]) -> Bool {
                    (item["filterText"] as? String ?? item["label"] as? String ?? "").hasPrefix(typedPrefix)
                }
                let left = exactCase(lhs.element), right = exactCase(rhs.element)
                return left == right ? lhs.offset < rhs.offset : left
            }.map(\.element)
            for item in ranked.prefix(100) {
                guard let label = item["label"] as? String else { continue }
                let edit = item["textEdit"] as? [String:Any], range = edit?["range"] as? [String:Any]
                let start = (range?["start"] as? [String:Any]).flatMap { SwiftLanguage.offset($0,in:request.text) } ?? request.cursor
                let end = (range?["end"] as? [String:Any]).flatMap { SwiftLanguage.offset($0,in:request.text) } ?? request.cursor
                guard start <= end else { continue }
                let text = edit?["newText"] as? String ?? item["insertText"] as? String ?? label
                result.completions.append(SwiftIDECompletion(label:label,detail:item["detail"] as? String ?? "",text:text,start:start,end:end))
            }
            result.message = result.completions.isEmpty ? "SourceKit-LSP: no completions at this position" : "Swift completions (Enter insert, Esc close)"
        } else {
            let locations = raw as? [[String:Any]] ?? (raw as? [String:Any]).map { [$0] } ?? []
            let prefix = WebIsolation.canonical(root.appendingPathComponent("Sources").path)+"/"
            for location in locations {
                guard let uri = location["uri"] as? String ?? location["targetUri"] as? String,
                      let url = URL(string:uri), url.isFileURL else { continue }
                let absolute = WebIsolation.canonical(url.path)
                let path = String(absolute.dropFirst(prefix.count))
                let range = location["range"] as? [String:Any] ?? location["targetSelectionRange"] as? [String:Any]
                guard absolute.hasPrefix(prefix), snapshot.files[path] != nil, let start = range?["start"] as? [String:Any],
                      let line = start["line"] as? Int, let column = start["character"] as? Int else { continue }
                result.locations.append(SwiftIDELocation(path:path,line:line+1,column:column+1))
            }
            result.message = result.locations.isEmpty ? "No project definition at this position (SDK definitions are outside this project's file grant)" : "Swift definitions (Enter or click to open)"
        }
        return result
    }
}
