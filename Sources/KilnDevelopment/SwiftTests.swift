import Foundation
import KilnKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct SwiftTestPlan: Codable { let list: Bool; let filter: String?; var moduleOnly: Bool? = nil }
extension WebDevelopment {
    func test(module: String, request: SwiftIDERequest, snapshot: WebFiles, sdk: WebBuildSDK, progress: @escaping @Sendable (String) -> Void) async throws -> SwiftIDEResult {
        guard sdk.testArguments != nil else { throw KilnError.message("Tests require an updated testing-capable SDK; export and register it first") }
        guard (request.testFilter?.utf8.count ?? 0) <= 2048 else { throw KilnError.message("Test selection is too long") }
        guard snapshot.files.keys.contains(where:{$0.hasPrefix("Tests/") && $0.hasSuffix(".swift")}) else {
            var result = SwiftIDEResult(action:request.action,message:"No Swift tests. Add Tests/*.swift, import Testing and @testable import KilnApplication.")
            result.tests = []; return result
        }
        let root = directory.appendingPathComponent("ide/tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        try snapshot.writeSources(at:root.appendingPathComponent("Sources")); try snapshot.save(at:root)
        try KilnStateFile.write(JSONEncoder().encode(sdk),to:root.appendingPathComponent("sdk.json"))
        try KilnStateFile.write(JSONEncoder().encode(SwiftTestPlan(list:request.action == "testList",filter:request.testFilter)),to:root.appendingPathComponent("TestPlan.json"))
        progress("Compiling application and tests")
        do { try await compile(sdk:sdk,job:root,progress:progress) }
        catch is CancellationError { throw CancellationError() }
        catch {
            let log = (try? String(contentsOf:root.appendingPathComponent("build.log"),encoding:.utf8)) ?? String(describing:error)
            var result = SwiftIDEResult(action:request.action,message:"Test build failed. Draft and release preserved.\n"+String(log.prefix(16000)))
            result.locations = try Self.compilerLocations(log:log,root:root,files:Set(snapshot.files.keys)); return result
        }
        let dataRoot = root.appendingPathComponent("Run")
        try FileManager.default.createDirectory(at:dataRoot,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let log = root.appendingPathComponent("test.log")
        try KilnStateFile.write(Data(),to:log)
        let output = try FileHandle(forWritingTo:log); defer { try? output.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath:sdk.builder); process.arguments = ["--test-run",root.path]
        process.environment = ["HOME":dataRoot.path,"TMPDIR":dataRoot.path+"/","PATH":"/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = output
        progress(request.action == "testList" ? "Discovering Swift tests" : "Running Swift tests")
        try process.run()
        defer {
            _ = kill(-process.processIdentifier,SIGKILL)
            if process.isRunning { _ = kill(process.processIdentifier,SIGKILL) }
        }
        let deadline = Date().addingTimeInterval(120), start = Date()
        var previous = "", lastUpdate = Date.distantPast
        let eventsURL = dataRoot.appendingPathComponent("events.jsonl")
        while process.isRunning {
            try Task.checkCancellation()
            let logSize = (try? FileManager.default.attributesOfItem(atPath:log.path)[.size] as? NSNumber)?.intValue ?? 0
            let eventSize = (try? FileManager.default.attributesOfItem(atPath:eventsURL.path)[.size] as? NSNumber)?.intValue ?? 0
            guard Date() < deadline, logSize <= 65536, eventSize <= 2_097_152 else { throw KilnError.message("Test run exceeded time or output limits; draft and release preserved") }
            if Date().timeIntervalSince(lastUpdate) >= 0.2, let data = try? Data(contentsOf:eventsURL) {
                let events = try SwiftTestEvents(data:data,files:Set(snapshot.files.keys),sourceRoot:root.appendingPathComponent("Sources"))
                let status = "Tests: "+events.summary+" (\(Int(Date().timeIntervalSince(start)))s)"
                if previous != status { progress(status); previous = status }; lastUpdate = Date()
            }
            try await Task.sleep(for:.milliseconds(50))
        }
        try Task.checkCancellation()
        let outputBytes = try WebFiles.readFile(log,limit:65536)
        let bytes = FileManager.default.fileExists(atPath:eventsURL.path) ? try WebFiles.readFile(eventsURL,limit:2_097_152) : Data()
        let events = try SwiftTestEvents(data:bytes,files:Set(snapshot.files.keys),sourceRoot:root.appendingPathComponent("Sources"))
        let complete = request.action == "testList" ? process.terminationStatus == 0 : events.started && events.ended && (process.terminationStatus == 0 || process.terminationStatus == 1 && events.issueCount > 0)
        let noMatch = request.action == "test" && !events.tests.contains(where:{$0.state != "discovered"})
        let message: String
        if request.action == "testList" { message = "Swift tests: \(events.tests.count) discovered" }
        else if !complete { message = "Test run incomplete; results are partial.\n"+String(decoding:outputBytes,as:UTF8.self) }
        else if noMatch { message = "No tests matched the selection" }
        else { message = "Tests finished: "+events.summary+" / \(events.issueCount) issues" }
        var result = SwiftIDEResult(action:request.action,message:message)
        result.tests = events.tests.sorted { a,b in a.state == "failed" && b.state != "failed" || (a.state == "failed") == (b.state == "failed") && a.name < b.name }
        result.locations = events.globalFailures + events.tests.flatMap(\.failures)
        return result
    }
    static func compilerLocations(log: String, root: URL, files: Set<String>) throws -> [SwiftIDELocation] {
        let regex = try NSRegularExpression(pattern:"^(.+\\.swift):(\\d+):(\\d+): (error|warning|note): (.+)$",options:.anchorsMatchLines)
        let prefix = WebIsolation.canonical(root.appendingPathComponent("Sources").path)+"/"
        return regex.matches(in:log,range:NSRange(log.startIndex...,in:log)).prefix(64).compactMap { match in
            func group(_ n: Int) -> String { Range(match.range(at:n),in:log).map { String(log[$0]) } ?? "" }
            let absolute = WebIsolation.canonical(group(1)), path = String(absolute.dropFirst(prefix.count))
            guard absolute.hasPrefix(prefix), files.contains(path), let line = Int(group(2)), let column = Int(group(3)) else { return nil }
            return SwiftIDELocation(path:path,line:line,column:column,message:group(4)+": "+group(5))
        }
    }
}

extension WebIsolation {
    public static func runTests(job: String) throws -> Never {
        guard supported else { throw KilnError.message("Isolated Swift tests require macOS") }
        let root = URL(fileURLWithPath:canonical(job))
        let sdk = try JSONDecoder().decode(WebBuildSDK.self,from:Data(contentsOf:root.appendingPathComponent("sdk.json")))
        try sdk.validate(); try sdk.verifyInputs()
        let plan = try JSONDecoder().decode(SwiftTestPlan.self,from:Data(contentsOf:root.appendingPathComponent("TestPlan.json")))
        guard sdk.testArguments != nil, (plan.filter?.utf8.count ?? 0) <= 2048 else { throw KilnError.message("Invalid test plan") }
        if getpgrp() != getpid(), setpgid(0,0) != 0 { throw KilnError.message("Cannot establish test process group") }
        let binary = root.appendingPathComponent("tests").path, data = root.appendingPathComponent("Run").path
        let libraries = (sdk.runtimeLibraries+(sdk.testReadRoots ?? [])).map { "(subpath \(quote(canonical($0))))" }.joined(separator:" ")
        let profile = systemProfile()+"\n(allow process-exec (literal \(quote(binary))))\n(allow file-read* (literal \(quote(binary))) \(libraries))\n(allow file-read* file-write* (subpath \(quote(data))))"
        guard chdir(data) == 0 else { throw KilnError.message("Test scratch directory unavailable") }
        for key in ProcessInfo.processInfo.environment.keys { unsetenv(key) }
        for (key,value) in ["HOME":data,"TMPDIR":data+"/","PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8"] { setenv(key,value,1) }
        var args = [binary,"--event-stream-output-path",data+"/events.jsonl","--experimental-event-stream-version","0"]
        if plan.list { args.append("--list-tests") }
        if let filter = plan.filter { args += ["--filter","^"+NSRegularExpression.escapedPattern(for:filter)+"$"] }
        try replace(arguments:["/usr/bin/sandbox-exec","-p",profile]+args)
    }
}
