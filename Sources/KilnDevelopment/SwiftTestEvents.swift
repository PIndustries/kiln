import Foundation
import KilnKit

/// Swift Testing JSON Lines v0. Unknown record/event kinds are forward-compatible;
/// incomplete or unsupported streams never become a successful test result.
struct SwiftTestEvents {
    var tests: [SwiftIDETest] = []
    var issueCount = 0
    var ended = false
    var started = false
    var globalFailures: [SwiftIDELocation] = []
    init(data: Data, files: Set<String>, sourceRoot: URL) throws {
        guard data.count <= 2_097_152 else { throw KilnError.message("Test event stream exceeded 2 MiB") }
        func location(_ raw: Any?, message: String = "") -> SwiftIDELocation? {
            guard let value = raw as? [String:Any], let line = value["line"] as? Int, let column = value["column"] as? Int, line > 0, column > 0 else { return nil }
            let path: String?
            if let absolute = (value["filePath"] ?? value["_filePath"]) as? String {
                guard absolute.hasPrefix(sourceRoot.path+"/") else { return nil }
                path = String(absolute.dropFirst(sourceRoot.path.count+1))
            } else if let id = value["fileID"] as? String {
                let name = id.split(separator:"/").dropFirst().joined(separator:"/")
                let matches = files.filter { $0 == name || $0.hasSuffix("/"+name) }
                path = matches.count == 1 ? matches.first : nil
            } else { path = nil }
            guard let path, files.contains(path), WebFiles.validPath(path) else { return nil }
            return SwiftIDELocation(path:path,line:line,column:column,message:message)
        }
        let lines = data.split(separator:10,omittingEmptySubsequences:true)
        for (index,line) in lines.enumerated() {
            guard let object = try? JSONSerialization.jsonObject(with:Data(line)) as? [String:Any] else {
                if index == lines.count-1 && data.last != 10 { break }
                throw KilnError.message("Malformed test event stream")
            }
            guard object["version"] as? Int == 0 else { throw KilnError.message("Unsupported Swift Testing event schema") }
            guard let payload = object["payload"] as? [String:Any] else { continue }
            if object["kind"] as? String == "test", payload["kind"] as? String == "function", let id = payload["id"] as? String, let name = payload["displayName"] as? String ?? payload["name"] as? String {
                guard tests.count < 256, id.utf8.count <= 2048, name.utf8.count <= 1024, !tests.contains(where:{$0.id == id}) else { throw KilnError.message("Duplicate or excessive test inventory") }
                tests.append(SwiftIDETest(id:id,name:name,location:location(payload["sourceLocation"]))); continue
            }
            guard object["kind"] as? String == "event", let kind = payload["kind"] as? String else { continue }
            if kind == "runStarted" { started = true }
            if kind == "runEnded" { ended = true }
            let test = (payload["testID"] as? String).flatMap { id in tests.firstIndex(where:{$0.id == id}) }
            switch kind {
            case "testStarted": if let test { tests[test].state = "running" }
            case "testSkipped": if let test { tests[test].state = "skipped" }
            case "testEnded": if let test, tests[test].state == "running" { tests[test].state = "passed" }
            case "issueRecorded":
                guard let issue = payload["issue"] as? [String:Any], issue["isKnown"] as? Bool != true else { continue }
                issueCount += 1
                let messages = (payload["messages"] as? [[String:Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator:"; ")
                guard messages.utf8.count <= 16384, globalFailures.count+tests.reduce(0,{$0+$1.failures.count}) < 512 else { throw KilnError.message("Test issue limit exceeded") }
                let target = location(issue["sourceLocation"],message:messages)
                if let test {
                    tests[test].state = "failed"
                    let fallback = tests[test].location.map { SwiftIDELocation(path:$0.path,line:$0.line,column:$0.column,message:messages) }
                    if let failure = target ?? fallback { tests[test].failures.append(failure) }
                } else if let target { globalFailures.append(target) }
            default: break
            }
        }
    }
    var summary: String {
        "\(tests.filter{$0.state == "passed"}.count) passed / \(tests.filter{$0.state == "failed"}.count) failed / \(tests.filter{$0.state == "running"}.count) running / \(tests.filter{$0.state == "skipped"}.count) skipped"
    }
}
