import Foundation
import KilnKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct SwiftLanguageSession: Sendable {
    let signature: String
    let root: URL
    let service: SwiftLanguage
    let token: String
    var used: Date
}
struct SwiftLanguageReply: Sendable {
    let data: Data
    let sessionID: String
    let version: Int
}

/// Persistent transport owned by one authenticated editor lane. All document
/// contents are private snapshots; package manifests and plugins never execute.
actor SwiftLanguage {
    let sdk: WebBuildSDK
    let root: URL
    private var process: Process?
    private var input: FileHandle?, output: FileHandle?
    private var buffer = Data(), sequence = 0
    private var texts: [String:String] = [:], versions: [String:Int] = [:]
    private var capabilities: [String:Any] = [:]
    private var busy = false
    private var sessionID = UUID().uuidString.lowercased()
    private var indexFingerprint: String?
    private var indexRows: [SwiftIndexOccurrence] = []
    init(sdk: WebBuildSDK, root: URL) { self.sdk = sdk; self.root = root }
    deinit {
        if let process, process.isRunning { process.terminate(); _ = kill(process.processIdentifier,SIGKILL) }
        try? input?.close(); try? output?.close()
        try? FileManager.default.removeItem(at:root)
    }
    func stop() {
        if let process, process.isRunning { process.terminate(); _ = kill(process.processIdentifier,SIGKILL) }
        try? input?.close(); try? output?.close()
        process = nil; input = nil; output = nil
        buffer = Data(); sequence = 0; texts = [:]; versions = [:]; capabilities = [:]
    }
    func shutdown() { stop(); try? FileManager.default.removeItem(at:root) }
    private func uri(_ path: String) -> String { root.appendingPathComponent(path).absoluteString }
    private func send(_ value: [String:Any]) throws {
        guard let input else { throw KilnError.message("Swift language session is closed") }
        var value = value; value["jsonrpc"] = "2.0"
        let data = try JSONSerialization.data(withJSONObject:value)
        try input.write(contentsOf:Data("Content-Length: \(data.count)\r\n\r\n".utf8)+data)
    }
    private func request(_ method: String, _ params: [String:Any]) async throws -> Any {
        sequence += 1; let id = sequence
        try send(["id":id,"method":method,"params":params])
        let deadline = ContinuousClock.now.advanced(by:.seconds(30))
        var total = 0
        do {
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                if let boundary = buffer.range(of:Data("\r\n\r\n".utf8)) {
                    let header = String(decoding:buffer[..<boundary.lowerBound],as:UTF8.self)
                    guard header.utf8.count <= 8192,
                          let line = header.components(separatedBy:"\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                          let count = Int(line.dropFirst(15).trimmingCharacters(in:.whitespaces)), (0...4_194_304).contains(count) else { throw KilnError.message("Invalid SourceKit-LSP frame") }
                    if buffer.count >= boundary.upperBound+count {
                        let bytes = buffer.subdata(in:boundary.upperBound..<boundary.upperBound+count)
                        buffer.removeSubrange(..<(boundary.upperBound+count))
                        guard let object = try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { throw KilnError.message("Invalid SourceKit-LSP message") }
                        if let method = object["method"] as? String, let serverID = object["id"] {
                            if method == "workspace/configuration" {
                                let items = (object["params"] as? [String:Any])?["items"] as? [Any] ?? []
                                try send(["id":serverID,"result":items.map { _ in NSNull() }])
                            } else if method == "workspace/applyEdit" {
                                try send(["id":serverID,"result":["applied":false,"failureReason":"Kiln applies reviewed, version-checked editor changes itself"]])
                            } else if method == "client/registerCapability" {
                                for registration in (object["params"] as? [String:Any])?["registrations"] as? [[String:Any]] ?? [] {
                                    if registration["method"] as? String == "textDocument/diagnostic" { capabilities["diagnosticProvider"] = registration["registerOptions"] ?? true }
                                }
                                try send(["id":serverID,"result":NSNull()])
                            } else if method == "window/workDoneProgress/create" {
                                try send(["id":serverID,"result":NSNull()])
                            } else { try send(["id":serverID,"error":["code":-32601,"message":"Unsupported client request"]]) }
                            continue
                        }
                        if object["id"] as? Int == id {
                            if let error = object["error"] as? [String:Any] { throw KilnError.message("SourceKit-LSP: "+(error["message"] as? String ?? "request failed")) }
                            return object["result"] ?? NSNull()
                        }
                        continue
                    }
                } else if buffer.count > 8192 { throw KilnError.message("Oversized SourceKit-LSP header") }
                guard let output else { throw KilnError.message("Swift language session is closed") }
                var chunk = [UInt8](repeating:0,count:65536)
                let count = read(output.fileDescriptor,&chunk,chunk.count)
                if count > 0 {
                    total += count; guard total <= 8_388_608 else { throw KilnError.message("SourceKit-LSP reply exceeded its resource guard") }
                    buffer.append(contentsOf:chunk.prefix(count))
                } else {
                    if count == 0 || process?.isRunning != true { throw KilnError.message("SourceKit-LSP stopped before replying") }
                    if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw KilnError.message("Cannot read SourceKit-LSP reply") }
                    try await Task.sleep(for:.milliseconds(10))
                }
            }
            throw KilnError.message("SourceKit-LSP request timed out")
        } catch {
            try? send(["method":"$/cancelRequest","params":["id":id]])
            throw error
        }
    }
    private func launch(_ files: [String:String]) async throws {
        let compiler = URL(fileURLWithPath:sdk.compiler), executable = URL(fileURLWithPath:sdk.compiler).deletingLastPathComponent().appendingPathComponent("sourcekit-lsp")
        guard FileManager.default.isExecutableFile(atPath:executable.path) else { throw KilnError.message("SourceKit-LSP is missing from the registered Swift toolchain") }
        let paths = files.keys.sorted().map { root.appendingPathComponent($0) }
        let database: [[String:Any]] = paths.map { file in
            ["directory":root.path,"file":file.path,"arguments":[sdk.compiler]+sdk.arguments+["-typecheck",file.path]+paths.filter { $0 != file }.map(\.path)]
        }
        try KilnStateFile.write(JSONSerialization.data(withJSONObject:database),to:root.appendingPathComponent("compile_commands.json"))
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), child = Process()
        child.executableURL = URL(fileURLWithPath:"/usr/bin/sandbox-exec")
        let resources = compiler.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/sourcekitd.framework/Resources/xpc_service_name.txt")
        let service = (try? String(contentsOf:resources,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)) ?? ""
        let xpc = service.isEmpty ? "" : "\n(allow job-creation)(allow mach-lookup (global-name \(WebIsolation.quote(service))))"
        child.arguments = ["-p",WebIsolation.buildProfile(sdk:sdk,job:root.path)+xpc,executable.path,"--default-workspace-type","compilationDatabase"]
        child.currentDirectoryURL = root
        child.environment = ["HOME":root.path,"TMPDIR":root.path+"/","PATH":compiler.deletingLastPathComponent().path+":/usr/bin:/bin","LANG":"en_US.UTF-8"]
        child.standardInput = stdinPipe; child.standardOutput = stdoutPipe; child.standardError = FileHandle.nullDevice
        input = stdinPipe.fileHandleForWriting; output = stdoutPipe.fileHandleForReading; process = child
        try child.run()
        let fd = stdoutPipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK)
        sessionID = UUID().uuidString.lowercased()
        let result = try await request("initialize",["processId":ProcessInfo.processInfo.processIdentifier,"rootUri":root.absoluteString,
            "capabilities":["textDocument":["completion":["completionItem":["snippetSupport":false]],"diagnostic":["dynamicRegistration":true],"codeAction":["codeActionLiteralSupport":["codeActionKind":["valueSet":["quickfix","refactor"]]],"disabledSupport":true]],"workspace":["workspaceEdit":["documentChanges":true]]],
            "initializationOptions":["backgroundIndexing":false]])
        capabilities = (result as? [String:Any])?["capabilities"] as? [String:Any] ?? [:]
        try send(["method":"initialized","params":[:]])
    }
    func query(files: [String:String], selected: String, action: String, cursor: Int, newName: String?) async throws -> SwiftLanguageReply {
        guard !busy, let source = files[selected], (0...source.count).contains(cursor) else { throw KilnError.message("Swift language session is busy or its document is invalid") }
        busy = true; defer { busy = false }
        do {
            for (path,text) in files {
                let file = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                if texts[path] != text { try KilnStateFile.write(Data(text.utf8),to:file) }
            }
            if process?.isRunning != true { stop(); try await launch(files) }
            for path in files.keys.sorted() {
                let text = files[path]!
                if texts[path] == nil {
                    try send(["method":"textDocument/didOpen","params":["textDocument":["uri":uri(path),"languageId":"swift","version":1,"text":text]]])
                    versions[path] = 1
                } else if texts[path] != text {
                    versions[path,default:0] += 1
                    try send(["method":"textDocument/didChange","params":["textDocument":["uri":uri(path),"version":versions[path]!],"contentChanges":[["text":text]]]])
                }
                texts[path] = text
            }
            let prefix = String(source.prefix(cursor)), line = prefix.filter { $0 == "\n" }.count
            let column = prefix.components(separatedBy:"\n").last!.utf16.count
            if action == "references" || action == "rename" {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let fingerprint = WebIsolation.digest(try encoder.encode(files))
                if indexFingerprint != fingerprint {
                    let rows = try await SwiftProjectIndex.build(sdk:sdk,root:root,files:files)
                    indexRows = rows; indexFingerprint = fingerprint
                }
                if let response = try SwiftProjectIndex.response(rows:indexRows,files:files,root:root,selected:selected,cursor:cursor,action:action,newName:newName) {
                    return SwiftLanguageReply(data:try JSONSerialization.data(withJSONObject:response),sessionID:sessionID,version:versions[selected]!)
                }
            }
            var params: [String:Any] = ["textDocument":["uri":uri(selected)],"position":["line":line,"character":column]]
            let method: String
            switch action {
            case "complete": method = "completion"
            case "definition": method = "definition"
            case "references": method = "references"; params["context"] = ["includeDeclaration":true]
            case "rename": method = "rename"; params["newName"] = newName
            case "format":
                method = "formatting"; params = ["textDocument":["uri":uri(selected)],"options":["tabSize":4,"insertSpaces":true]]
            case "codeActions":
                method = "codeAction"
                let report = try await request("textDocument/diagnostic",["textDocument":["uri":uri(selected)]]) as? [String:Any]
                let items = (report?["items"] as? [[String:Any]] ?? []).filter { item in
                    guard let range = item["range"] as? [String:Any], let start = range["start"] as? [String:Any], let end = range["end"] as? [String:Any],
                          let first = start["line"] as? Int, let last = end["line"] as? Int else { return false }
                    return first <= line && line <= last
                }
                params = ["textDocument":["uri":uri(selected)],"range":["start":["line":line,"character":0],"end":["line":line,"character":source.components(separatedBy:"\n")[line].utf16.count]],"context":["diagnostics":items]]
            case "diagnostics":
                method = "diagnostic"; params.removeValue(forKey:"position")
            default: throw KilnError.message("Unsupported Swift language request")
            }
            var result = try await request("textDocument/"+method,params)
            if action == "format" {
                guard let edits = result as? [[String:Any]] else { throw KilnError.message("Swift toolchain returned no formatting edits") }
                result = ["changes":[uri(selected):edits]]
            }
            var coverage: String? = action == "rename" ? "document" : nil
            if action == "references", (result as? [Any])?.isEmpty != false {
                // Older SourceKit versions require an index for references, but
                // still provide semantic highlights for the current document.
                // Surface this narrower coverage instead of pretending a text
                // search resolved project-wide symbol identity.
                let highlights = try await request("textDocument/documentHighlight",["textDocument":["uri":uri(selected)],"position":["line":line,"character":column]])
                result = (highlights as? [[String:Any]] ?? []).compactMap { highlight -> [String:Any]? in
                    guard let range = highlight["range"] else { return nil }
                    return ["uri":uri(selected),"range":range]
                }
                coverage = "document"
            }
            let workspaceEdits: [[String:Any]] = action == "codeActions" ? (result as? [[String:Any]] ?? []).compactMap { $0["edit"] as? [String:Any] } : (result as? [String:Any]).map { [$0] } ?? []
            for workspaceEdit in workspaceEdits {
                for edit in workspaceEdit["documentChanges"] as? [[String:Any]] ?? [] {
                    guard let document = edit["textDocument"] as? [String:Any], let target = document["uri"] as? String else { throw KilnError.message("Unsupported language-service resource operation") }
                    if let supplied = document["version"], !(supplied is NSNull) {
                        guard let version = supplied as? Int, let path = files.keys.first(where: { uri($0) == target }), versions[path] == version else { throw KilnError.message("Source edit belongs to a stale or invalid Swift document version") }
                    }
                }
            }
            var object: [String:Any] = ["value":result]
            if let coverage { object["coverage"] = coverage }
            return SwiftLanguageReply(data:try JSONSerialization.data(withJSONObject:object),sessionID:sessionID,version:versions[selected]!)
        } catch { stop(); throw error }
    }
    nonisolated static func offset(_ position: [String:Any], in text: String) -> Int? {
        guard let line = position["line"] as? Int, let column = position["character"] as? Int, line >= 0, column >= 0 else { return nil }
        let rows = text.components(separatedBy:"\n")
        guard rows.indices.contains(line), column <= rows[line].utf16.count,
              let index = String.Index(utf16Offset:column,in:rows[line]).samePosition(in:rows[line]) else { return nil }
        return rows.prefix(line).reduce(0){$0+$1.count+1}+rows[line].distance(from:rows[line].startIndex,to:index)
    }
}
