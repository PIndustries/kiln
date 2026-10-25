import Foundation
import KilnKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A short-lived language session over a private source snapshot. No package
/// manifests/plugins execute, and only the registered SDK supplies build flags.
struct SwiftLanguage {
    let sdk: WebBuildSDK
    let root: URL
    let paths: [String]
    let source: String
    let selected: String

    func query(action: String, cursor: Int) async throws -> Data {
        let compiler = URL(fileURLWithPath:sdk.compiler)
        let executable = compiler.deletingLastPathComponent().appendingPathComponent("sourcekit-lsp")
        guard FileManager.default.isExecutableFile(atPath:executable.path) else { throw KilnError.message("SourceKit-LSP is missing from the registered Swift toolchain") }
        let files = paths.map { root.appendingPathComponent("Sources/"+$0) }
        let database: [[String:Any]] = files.map { file in
            ["directory":root.path,"file":file.path,"arguments":[sdk.compiler]+sdk.arguments+["-typecheck",file.path]+files.filter { $0 != file }.map(\.path)]
        }
        try KilnStateFile.write(JSONSerialization.data(withJSONObject:database),to:root.appendingPathComponent("compile_commands.json"))
        let input = Pipe(), output = Pipe(), process = Process()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/sandbox-exec")
        let resources = compiler.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/sourcekitd.framework/Resources/xpc_service_name.txt")
        let service = (try? String(contentsOf:resources,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)) ?? ""
        let xpc = service.isEmpty ? "" : "\n(allow job-creation)(allow mach-lookup (global-name \(WebIsolation.quote(service))))"
        process.arguments = ["-p",WebIsolation.buildProfile(sdk:sdk,job:root.path)+xpc,executable.path,"--default-workspace-type","compilationDatabase"]
        process.currentDirectoryURL = root
        process.environment = ["HOME":root.path,"TMPDIR":root.path+"/","PATH":compiler.deletingLastPathComponent().path+":/usr/bin:/bin","LANG":"en_US.UTF-8"]
        let logURL = root.appendingPathComponent("language.log")
        try KilnStateFile.write(Data(),to:logURL)
        let log = try FileHandle(forWritingTo:logURL); defer { try? log.close() }
        process.standardInput = input; process.standardOutput = output; process.standardError = log
        try process.run()
        defer { if process.isRunning { process.terminate(); _ = kill(process.processIdentifier,SIGKILL) }; try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close() }
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK)
        var buffer = Data(), total = 0, sequence = 0
        func send(_ value: [String:Any]) throws {
            var value = value; value["jsonrpc"] = "2.0"
            let data = try JSONSerialization.data(withJSONObject:value)
            try input.fileHandleForWriting.write(contentsOf:Data("Content-Length: \(data.count)\r\n\r\n".utf8)+data)
        }
        func request(_ method: String, _ params: [String:Any]) async throws -> Any {
            sequence += 1; let id = sequence
            try send(["id":id,"method":method,"params":params])
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                try Task.checkCancellation()
                if let boundary = buffer.range(of:Data("\r\n\r\n".utf8)) {
                    let header = String(decoding:buffer[..<boundary.lowerBound],as:UTF8.self)
                    guard let countLine = header.components(separatedBy:"\r\n").first(where:{$0.lowercased().hasPrefix("content-length:")}),
                          let count = Int(countLine.dropFirst(15).trimmingCharacters(in:.whitespaces)), (0...4_194_304).contains(count) else { throw KilnError.message("Invalid SourceKit-LSP frame") }
                    if buffer.count >= boundary.upperBound+count {
                        let bytes = buffer.subdata(in:boundary.upperBound..<boundary.upperBound+count)
                        buffer.removeSubrange(..<(boundary.upperBound+count))
                        guard let object = try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { continue }
                        if let method = object["method"] as? String, let serverID = object["id"] {
                            let result: Any = method == "workspace/configuration" ? [] : NSNull()
                            try send(["id":serverID,"result":result]); continue
                        }
                        if object["id"] as? Int == id {
                            if let error = object["error"] as? [String:Any] { throw KilnError.message("SourceKit-LSP: "+(error["message"] as? String ?? "request failed")) }
                            return object["result"] ?? NSNull()
                        }
                        continue
                    }
                }
                var chunk = [UInt8](repeating:0,count:65536)
                let count = read(fd,&chunk,chunk.count)
                if count > 0 { total += count; guard total <= 8_388_608 else { throw KilnError.message("SourceKit-LSP response buffer exceeded its resource limit") }; buffer.append(contentsOf:chunk.prefix(count)) }
                else {
                    if !process.isRunning { throw KilnError.message("SourceKit-LSP stopped before replying: "+String(((try? String(contentsOf:logURL,encoding:.utf8)) ?? "").prefix(4000))) }
                    try await Task.sleep(for:.milliseconds(10))
                }
            }
            throw KilnError.message("SourceKit-LSP request timed out")
        }
        _ = try await request("initialize",["processId":ProcessInfo.processInfo.processIdentifier,"rootUri":root.absoluteString,
            "capabilities":["textDocument":["completion":["completionItem":["snippetSupport":false]]]],
            "initializationOptions":["backgroundIndexing":false]])
        try send(["method":"initialized","params":[:]])
        for file in files {
            let text = try String(contentsOf:file,encoding:.utf8)
            try send(["method":"textDocument/didOpen","params":["textDocument":["uri":file.absoluteString,"languageId":"swift","version":1,"text":text]]])
        }
        let prefix = String(source.prefix(cursor)), line = prefix.filter { $0 == "\n" }.count
        let column = prefix.components(separatedBy:"\n").last!.utf16.count
        let result = try await request("textDocument/"+(action == "complete" ? "completion" : "definition"),
            ["textDocument":["uri":root.appendingPathComponent("Sources/"+selected).absoluteString],"position":["line":line,"character":column]])
        return try JSONSerialization.data(withJSONObject:["value":result])
    }
    static func offset(_ position: [String:Any], in text: String) -> Int? {
        guard let line = position["line"] as? Int, let column = position["character"] as? Int, line >= 0, column >= 0 else { return nil }
        let rows = text.components(separatedBy:"\n")
        guard rows.indices.contains(line), column <= rows[line].utf16.count,
              let index = String.Index(utf16Offset:column,in:rows[line]).samePosition(in:rows[line]) else { return nil }
        return rows.prefix(line).reduce(0){$0+$1.count+1}+rows[line].distance(from:rows[line].startIndex,to:index)
    }
}
