import Foundation
import KilnKit

extension WebDevelopment {
    public func ide(module: String, request: SwiftIDERequest, scope: String = "local-console") async throws -> SwiftIDEResult {
        guard WebIsolation.supported, ideRequests < 4, ["complete","definition","references","diagnostics","rename","build"].contains(request.action),
              WebFiles.validPath(request.path), (request.path.hasSuffix(".swift") || request.action == "build"), request.text.utf8.count <= 65536,
              (0...request.text.count).contains(request.cursor) else { throw KilnError.message("Invalid Swift IDE request or language service busy") }
        let registered = try project(module)
        var snapshot = try WebFiles.read(registered.configuration)
        let disk = snapshot
        if request.action == "rename" {
            guard let name = request.newName, name.utf8.count <= 128, let first = name.first, first.isLetter || first == "_",
                  name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { throw KilnError.message("Use a Swift identifier as the new symbol name") }
        }
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
        ideRequests += 1
        defer { ideRequests -= 1 }
        if request.action == "build" {
            let root = directory.appendingPathComponent("ide/"+UUID().uuidString)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            defer { try? FileManager.default.removeItem(at:root) }
            try snapshot.writeSources(at:root.appendingPathComponent("Sources"))
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
        let key = WebIsolation.digest(Data((scope+"\n"+module).utf8))
        guard !languageBusy.contains(key) else { throw KilnError.message("Swift language session is busy") }
        languageBusy.insert(key); defer { languageBusy.remove(key) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let signature = WebIsolation.digest(try encoder.encode(registered.sdk))+"/"+snapshot.files.keys.sorted().joined(separator:"|")
        if let old = languageSessions[key], old.signature != signature {
            languageSessions.removeValue(forKey:key); languageExpiry.removeValue(forKey:key)?.cancel()
            await old.service.shutdown()
        }
        if languageSessions[key] == nil {
            if languageSessions.count+languageBusy.filter({ languageSessions[$0] == nil }).count > 4 {
                guard let victim = languageSessions.filter({ !languageBusy.contains($0.key) }).min(by: { $0.value.used < $1.value.used }) else { throw KilnError.message("All Swift language sessions are busy") }
                languageSessions.removeValue(forKey:victim.key); languageExpiry.removeValue(forKey:victim.key)?.cancel()
                await victim.value.service.shutdown()
            }
            let root = directory.appendingPathComponent("ide/language-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            languageSessions[key] = SwiftLanguageSession(signature:signature,root:root,service:SwiftLanguage(sdk:registered.sdk,root:root),token:UUID().uuidString,used:Date())
        }
        let session = languageSessions[key]!, root = session.root
        languageExpiry.removeValue(forKey:key)?.cancel()
        var files = snapshot.files.filter { $0.key.hasSuffix(".swift") }.reduce(into:[String:String]()) { $0["Sources/"+$1.key] = String(decoding:$1.value,as:UTF8.self) }
        if try WebTemplateCompiler.write(snapshot.files,at:root) != nil {
            files["GeneratedKilnViews.swift"] = try String(contentsOf:root.appendingPathComponent("GeneratedKilnViews.swift"),encoding:.utf8)
        }
        let reply: SwiftLanguageReply
        do { reply = try await session.service.query(files:files,selected:"Sources/"+request.path,action:request.action,cursor:request.cursor,newName:request.newName) }
        catch {
            languageSessions.removeValue(forKey:key); await session.service.shutdown(); throw error
        }
        languageSessions[key]?.used = Date()
        languageExpiry[key] = Task { [weak self] in
            do { try await Task.sleep(for:.seconds(120)) } catch { return }
            await self?.expireLanguage(key:key,token:session.token)
        }
        let response = try JSONSerialization.jsonObject(with:reply.data) as? [String:Any]
        let raw = response?["value"]
        var result = SwiftIDEResult(action:request.action,message:"SourceKit-LSP")
        result.sessionID = reply.sessionID; result.documentVersion = reply.version
        result.coverage = response?["coverage"] as? String
        if request.action == "diagnostics" {
            guard let report = raw as? [String:Any], report["kind"] as? String == "full",
                  let items = report["items"] as? [[String:Any]] else { throw KilnError.message("SourceKit did not return a complete diagnostic report") }
            for item in items.prefix(64) {
                guard let start = (item["range"] as? [String:Any])?["start"] as? [String:Any],
                      let line = start["line"] as? Int, let column = start["character"] as? Int, let message = item["message"] as? String else { continue }
                let label = (item["severity"] as? Int == 1 ? "error: " : item["severity"] as? Int == 2 ? "warning: " : "note: ")+message
                result.locations.append(SwiftIDELocation(path:request.path,line:line+1,column:column+1,message:label))
            }
            result.message = result.locations.isEmpty ? "No diagnostics in this document" : "Swift diagnostics (Enter or click to open)"
            return result
        }
        if request.action == "rename" { return try renameResult(raw,request:request,snapshot:snapshot,disk:disk,root:root,result:result) }
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
            result.message = result.locations.isEmpty ? "No project definition at this position (SDK definitions are outside this project's file grant)" : request.action == "references" ? "Swift references (Enter or click to open)" : "Swift definitions (Enter or click to open)"
            if request.action == "references", result.coverage == "project" { result.message = "Project references (Enter or click to open)" }
            if request.action == "references", response?["coverage"] as? String == "document" {
                result.message = result.locations.isEmpty ? "No document references here; project-wide index unavailable" : "Document references only; project-wide index unavailable"
            }
        }
        return result
    }
    private func expireLanguage(key: String, token: String) async {
        guard !languageBusy.contains(key), let session = languageSessions[key], session.token == token else { return }
        languageSessions.removeValue(forKey:key); languageExpiry.removeValue(forKey:key)
        await session.service.shutdown()
    }
    nonisolated func renameResult(_ raw: Any?, request: SwiftIDERequest, snapshot: WebFiles, disk: WebFiles, root: URL, result: SwiftIDEResult) throws -> SwiftIDEResult {
        guard let object = raw as? [String:Any] else { throw KilnError.message("SourceKit returned no rename edits at this position") }
        var changes = object["changes"] as? [String:[[String:Any]]] ?? [:]
        for item in object["documentChanges"] as? [[String:Any]] ?? [] {
            guard item["kind"] == nil, let document = item["textDocument"] as? [String:Any], let uri = document["uri"] as? String,
                  let edits = item["edits"] as? [[String:Any]], changes[uri] == nil else { throw KilnError.message("Rename returned unsupported file operations or duplicate documents") }
            changes[uri] = edits
        }
        let prefix = WebIsolation.canonical(root.appendingPathComponent("Sources").path)+"/"
        var result = result, updated = snapshot, proposals: [String:SwiftIDERenameFile] = [:], allEdits: [SwiftIDEEdit] = []
        for (uri,edits) in changes {
            guard let url = URL(string:uri), url.isFileURL else { throw KilnError.message("Rename escaped the registered project") }
            let absolute = WebIsolation.canonical(url.path), path = String(absolute.dropFirst(prefix.count))
            guard absolute.hasPrefix(prefix), let bytes = snapshot.files[path], path.hasSuffix(".swift"), let text = String(data:bytes,encoding:.utf8), edits.count <= 1024 else { throw KilnError.message("Rename includes an unavailable file or too many edits") }
            var replacements: [(Int,Int,String)] = []
            for edit in edits {
                guard let range = edit["range"] as? [String:Any], let start = range["start"] as? [String:Any], let end = range["end"] as? [String:Any],
                      let a = SwiftLanguage.offset(start,in:text), let b = SwiftLanguage.offset(end,in:text), a <= b, let replacement = edit["newText"] as? String,
                      let line = start["line"] as? Int, let column = start["character"] as? Int else { throw KilnError.message("Invalid Swift rename edit") }
                replacements.append((a,b,replacement))
                allEdits.append(SwiftIDEEdit(path:path,start:a,end:b,text:replacement,sha256:WebIsolation.digest(bytes)))
                result.locations.append(SwiftIDELocation(path:path,line:line+1,column:column+1,message:"rename to "+(request.newName ?? replacement)))
            }
            replacements.sort { $0.0 > $1.0 }
            var chars = Array(text), previous = chars.count+1
            for (a,b,replacement) in replacements {
                guard b <= previous, a < previous else { throw KilnError.message("Overlapping Swift rename edits") }
                chars.replaceSubrange(a..<b,with:replacement); previous = a
            }
            let changed = String(chars); updated.files[path] = Data(changed.utf8)
            let base = disk.files[path]
            proposals[path] = SwiftIDERenameFile(source:base.map { String(decoding:$0,as:UTF8.self) } ?? "",sha256:base.map(WebIsolation.digest) ?? "",text:changed)
        }
        try updated.validate()
        guard !proposals.isEmpty else { throw KilnError.message("No editable project references found for rename") }
        result.edits = allEdits; result.renameFiles = proposals
        result.message = "Rename proposal [\(result.coverage ?? "toolchain")]: \(allEdits.count) edits in \(proposals.count) files. Enter applies to drafts; publish separately."
        return result
    }

}
