import Foundation
import Testing
import KilnKit
@testable import KilnDevelopment

@Test func compilerIndexFindsCrossFileSymbolsWithoutRenamingShadowedNamesOrStrings() async throws {
    guard let sdkPath = ProcessInfo.processInfo.environment["KILN_SWIFT_IDE_SDK"], WebIsolation.supported else { return }
    let sdk = try JSONDecoder().decode(WebBuildSDK.self,from:Data(contentsOf:URL(fileURLWithPath:sdkPath)))
    try sdk.validate(); try sdk.verifyInputs()
    let root = URL(fileURLWithPath:WebIsolation.canonical(FileManager.default.temporaryDirectory.path)).appendingPathComponent("kiln-project-index-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    defer { try? FileManager.default.removeItem(at:root) }
    let app = "func make() -> Shared { Shared() }\nfunc shadow() { let Shared = 4; print(Shared) }\nlet text = \"Shared\" // Shared\n@main struct App { static func main() { _ = make() } }\n"
    let sources = ["App.swift":Data(app.utf8),"Models/Shared.swift":Data("struct Shared { let value = 1 }\n".utf8),"Consumer.swift":Data("func consume(_ item: Shared) -> Int { item.value }\n".utf8)]
    try WebFiles(files:sources).writeSources(at:root.appendingPathComponent("Sources"))
    let files = sources.reduce(into:[String:String]()) { $0["Sources/"+$1.key] = String(decoding:$1.value,as:UTF8.self) }
    let rows = try await SwiftProjectIndex.build(sdk:sdk,root:root,files:files)
    let cursor = app.distance(from:app.startIndex,to:app.range(of:"Shared")!.lowerBound)+1
    let referenceResponse = try SwiftProjectIndex.response(rows:rows,files:files,root:root,selected:"Sources/App.swift",cursor:cursor,action:"references",newName:nil)
    let response = try #require(referenceResponse)
    #expect(response["coverage"] as? String == "project")
    let locations = try #require(response["value"] as? [[String:Any]])
    #expect(Set(locations.compactMap { ($0["uri"] as? String).flatMap(URL.init(string:))?.lastPathComponent }) == ["App.swift","Shared.swift","Consumer.swift"])
    let renameResponse = try SwiftProjectIndex.response(rows:rows,files:files,root:root,selected:"Sources/App.swift",cursor:cursor,action:"rename",newName:"Device")
    let renamed = try #require(renameResponse)
    let edits = try #require((renamed["value"] as? [String:Any])?["changes"] as? [String:[[String:Any]]])
    let appEdits = try #require(edits[root.appendingPathComponent("Sources/App.swift").absoluteString])
    #expect(appEdits.count == 2)
    let result = try WebDevelopment(directory:root).renameResult(renamed["value"],request:SwiftIDERequest(action:"rename",path:"App.swift",sha256:WebIsolation.digest(sources["App.swift"]!),text:app,cursor:cursor,newName:"Device"),snapshot:WebFiles(files:sources),disk:WebFiles(files:sources),root:root,result:SwiftIDEResult(action:"rename",message:"test"))
    let proposal = try #require(result.renameFiles?["App.swift"]?.text)
    #expect(proposal.contains("func make() -> Device { Device() }"))
    #expect(proposal.contains("let Shared = 4; print(Shared)"))
    #expect(proposal.contains("\"Shared\" // Shared"))
    #expect(try WebFiles.readFile(root.appendingPathComponent("Sources/App.swift"),limit:65536) == sources["App.swift"])
}
@Test func compilerIndexCoordinatesConvertUTF8BytesToEditorUTF16() throws {
    let text = "let 😀 = 0; let café = 1\n", prefix = "let 😀 = 0; let "
    let row = SwiftIndexOccurrence(path:"Sources/App.swift",usr:"symbol",name:"café",kind:13,line:1,utf8Column:prefix.utf8.count+1,roles:2)
    let position = try #require(SwiftProjectIndex.position(row,text:text))
    #expect(position.offset == prefix.count)
    #expect(position.column == prefix.utf16.count)
    let token = try #require(SwiftProjectIndex.token(in:text,at:position.offset+1))
    #expect(token.name == "café")
    let invalid = SwiftIndexOccurrence(path:"Sources/App.swift",usr:"symbol",name:"café",kind:13,line:1,utf8Column:6,roles:2)
    #expect(SwiftProjectIndex.position(invalid,text:text) == nil)
}
@Test func compilerIndexRejectsUnavailableLibrariesRatherThanInventingResults() throws {
    do {
        _ = try SwiftProjectIndex.read(library:URL(fileURLWithPath:"/tmp/kiln-no-such-index-library"),store:URL(fileURLWithPath:"/tmp/kiln-no-such-index-store"),root:URL(fileURLWithPath:"/tmp/kiln-no-index-root"),allowed:["Sources/App.swift"])
        Issue.record("Unavailable index accepted")
    } catch { #expect(String(describing:error).contains("no partial project results")) }
}
