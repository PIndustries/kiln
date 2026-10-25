import Foundation
import Testing
import KilnKit
@testable import KilnDevelopment
@testable import KilnTerminal
@testable import KilnCommands

private func projectFolder() throws -> URL {
    let root = URL(fileURLWithPath:WebIsolation.canonical(FileManager.default.temporaryDirectory.path)).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700]); return root
}
private func projectConfig(_ root: URL) -> WebProjectConfiguration {
    WebProjectConfiguration(schemaVersion:1,module:"demo/web",source:root.appendingPathComponent("App.swift").path,sdk:"/unused",publicOrigin:"http://127.0.0.1:18085",ingressPort:18085,workerPorts:[18084,18086],autoPublish:true,root:root.path)
}
@Test func projectSnapshotsRejectEscapesStaleDeletesAndEntryPointRemoval() throws {
    let original = WebFiles(files:["App.swift":Data("import Foundation".utf8)])
    for path in ["../secret.swift","/tmp/x.swift",".env","a/../x.swift","a//x.swift","a/.git/x.swift","a/x.sh","a/\u{1b}.swift","a/🙂.swift"] { #expect(!WebFiles.validPath(path)) }
    let created = try original.applying("[{\"path\":\"Views/Header.swift\",\"action\":\"create\",\"content\":\"let title = 1\"}]",multiFile:true)
    #expect(created.files.count == 2)
    #expect(throws:(any Error).self) { try original.applying("[{\"path\":\"Views/Header.swift\",\"action\":\"create\",\"content\":\"x\"}]",multiFile:false) }
    #expect(throws:(any Error).self) { try created.applying("[{\"path\":\"Views/Header.swift\",\"action\":\"delete\",\"sha256\":\"stale\"}]",multiFile:true) }
    let sha = WebIsolation.digest(created.files["Views/Header.swift"]!)
    let deleted = try created.applying("[{\"path\":\"Views/Header.swift\",\"action\":\"delete\",\"sha256\":\"\(sha)\"}]",multiFile:true)
    #expect(deleted == original)
    #expect(throws:(any Error).self) { try original.applying("[{\"path\":\"App.swift\",\"action\":\"delete\",\"sha256\":\"\(WebIsolation.digest(original.files["App.swift"]!))\"}]",multiFile:true) }
    #expect(throws:(any Error).self) { try WebFiles(files:["App.swift":Data(),"a.swift":Data(),"a.swift/b.swift":Data()]).validate() }
}
@Test func projectTreeReadsOwnedTextRejectsSymlinksAndSwapsWholeSnapshots() throws {
    let parent = try projectFolder(); defer { try? FileManager.default.removeItem(at:parent) }
    let root = parent.appendingPathComponent("source"), config = projectConfig(root)
    let first = WebFiles(files:["App.swift":Data("first".utf8),"Views/Old.swift":Data("old".utf8)])
    try first.writeSources(at:root)
    #expect(try WebFiles.read(config) == first)
    let second = WebFiles(files:["App.swift":Data("second".utf8),"Components/New.swift":Data("new".utf8)])
    if WebIsolation.supported {
        try second.install(config,expected:first)
        #expect(try WebFiles.read(config) == second)
        #expect(!FileManager.default.fileExists(atPath:root.appendingPathComponent("Views/Old.swift").path))
        #expect(throws:(any Error).self) { try first.install(config,expected:first) }
        #expect(try WebFiles.read(config) == second)
    }
    let secret = parent.appendingPathComponent("outside.swift"); try KilnStateFile.write(Data("outside".utf8),to:secret)
    try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("Link.swift"),withDestinationURL:secret)
    #expect(throws:(any Error).self) { try WebFiles.read(config) }
    #expect(throws:(any Error).self) { try WebFiles.readFile(root.appendingPathComponent("Link.swift"),limit:65536) }
}
@Test func projectHistoryIncludesAddedDeletedFilesAndVerifiesWholeSnapshot() throws {
    let root = try projectFolder(); defer { try? FileManager.default.removeItem(at:root) }
    let before = WebFiles(files:["App.swift":Data("old".utf8),"Views/Removed.swift":Data("deleted line\n".utf8)])
    let after = WebFiles(files:["App.swift":Data("new".utf8),"Views/Added.swift":Data("added line\n".utf8)])
    let git = DevelopmentGit(directory:root)
    let commit = try git.commit(id:UUID().uuidString,version:"dev-test",files:after.files)
    #expect(commit.count == 40)
    let diff = try git.diff(before:before.files,after:after.files)
    #expect(diff.contains("Views/Removed.swift")); #expect(diff.contains("-deleted line"))
    #expect(diff.contains("Views/Added.swift")); #expect(diff.contains("+added line"))
    try after.save(at:root)
    #expect(try WebFiles.retained(at:root) == after)
    var tampered = after; tampered.files["Views/Added.swift"] = Data("tampered".utf8)
    #expect(try tampered.digest != after.digest)
}
@Test func syntaxLexerPreservesGeometryAndTracksMultilineTokens() {
    var syntax = SourceSyntax()
    let code = "let title: String = \"hello\" // comment"
    let colors = syntax.colors(code,path:"App.swift")
    #expect(colors.count == code.count)
    #expect(colors[0] == 141); #expect(colors[11] == 81)
    #expect(colors[21] == 114); #expect(colors.last! == 244)
    _ = syntax.colors("/* multi",path:"App.swift")
    #expect(syntax.colors("comment */ let n = 12",path:"App.swift")[0] == 244)
    let styled = SourceSyntax.styled(code,colors:colors,base:252)
    #expect(styled.contains("\u{1b}[38;5;141mlet"))
    var block = SourceSyntax(); _ = block.colors("let html = \"\"\"",path:"App.swift")
    #expect(block.colors("<h1>Hello</h1>",path:"App.swift").allSatisfy { $0 == 114 })
}
private func browserFixture(readOnly: Bool = false) throws -> String {
    let file: [String:Any] = ["file":"App.swift","sha256":"original-hash","source":"import Foundation\nlet number = 1\n","version":"workspace"]
    let tree: [String:Any] = ["version":"workspace","editable":!readOnly,"projectRoot":true,"files":[["path":"App.swift","sha256":"original-hash","bytes":32],["path":"Views/Header.swift","sha256":"header-hash","bytes":10]]]
    return String(decoding:try JSONSerialization.data(withJSONObject:["file":file,"tree":tree]),as:UTF8.self)
}
@Test func workspaceBrowserEditsAndCreatesThroughExplicitPublishAndKeepsHistoryReadOnly() throws {
    var browser = WorkspaceUI(module:"demo/web")
    browser.finish(text:try browserFixture(),status:0)
    let view = browser.render(width:120,height:35,theme:TerminalTheme())
    #expect(view.contains("+ Views/")); #expect(view.contains("Header.swift")); #expect(view.contains("\u{1b}[38;5;141mimport"))
    _ = browser.handle(.text("e"),width:120,height:35)
    _ = browser.handle(.text("// new\n"),width:120,height:35)
    #expect(browser.handle(.eof,width:120,height:35) == nil)
    // Cancel is selected first. Saving cannot execute on the first Enter.
    #expect(browser.handle(.enter,width:120,height:35) == nil)
    _ = browser.handle(.eof,width:120,height:35); _ = browser.handle(.down,width:120,height:35)
    let submitted = browser.handle(.enter,width:120,height:35)
    let command = try #require(submitted)
    let parts = try KilnCommands.tokenize(command)
    #expect(Array(parts.prefix(3)) == ["web","apply","demo/web"])
    let edits = try JSONDecoder().decode([[String:String]].self,from:Data(parts[3].utf8))
    #expect(edits[0]["sha256"] == "original-hash"); #expect(edits[0]["content"]?.hasPrefix("// new\n") == true)
    var retained = WorkspaceUI(module:"demo/web",change:"old-version")
    retained.finish(text:try browserFixture(readOnly:true),status:0)
    for key in [TerminalKey.text("e"),.text("a"),.text("x"),.eof,.enter] { #expect(retained.handle(key,width:120,height:35)?.contains("apply") != true) }
}
@Test func workspaceBrowserCreatesAndDeletesFilesUsingMatchingHashAndConfirmation() throws {
    var browser = WorkspaceUI(module:"demo/web")
    browser.finish(text:try browserFixture(),status:0)
    _ = browser.handle(.text("a"),width:120,height:35)
    _ = browser.handle(.text("Components/Footer.swift"),width:120,height:35)
    _ = browser.handle(.enter,width:120,height:35)
    _ = browser.handle(.paste("import Foundation\nlet footer = \"P.Industries\"\n"),width:120,height:35)
    _ = browser.handle(.eof,width:120,height:35); _ = browser.handle(.down,width:120,height:35)
    let creation = browser.handle(.enter,width:120,height:35)
    let createParts = try KilnCommands.tokenize(#require(creation))
    let create = try JSONDecoder().decode([[String:String]].self,from:Data(createParts[3].utf8))[0]
    #expect(create["action"] == "create"); #expect(create["path"] == "Components/Footer.swift")
    var deletion = WorkspaceUI(module:"demo/web")
    deletion.finish(text:try browserFixture(),status:0)
    _ = deletion.handle(.down,width:120,height:35)
    #expect(deletion.handle(.enter,width:120,height:35) == "'web' 'file' 'demo/web' 'Views/Header.swift'")
    deletion.finish(text:"{\"file\":\"Views/Header.swift\",\"sha256\":\"header-hash\",\"source\":\"let header = 1\",\"version\":\"workspace\"}",status:0)
    _ = deletion.handle(.text("x"),width:120,height:35)
    #expect(deletion.handle(.enter,width:120,height:35) == nil)
    _ = deletion.handle(.text("x"),width:120,height:35); _ = deletion.handle(.down,width:120,height:35)
    let removal = deletion.handle(.enter,width:120,height:35)
    let deleteParts = try KilnCommands.tokenize(#require(removal))
    let deleted = try JSONDecoder().decode([[String:String]].self,from:Data(deleteParts[3].utf8))[0]
    #expect(deleted["action"] == "delete"); #expect(deleted["sha256"] == "header-hash")
}
@Test func atomicRefactorOperationLimitDoesNotExpandOrdinaryEdits() throws {
    let snapshot = WebFiles(files:["App.swift":Data("import Foundation".utf8)])
    let ops = (0..<9).map { ["path":"Parts/Part\($0).swift","action":"create","content":"// part \($0)"] }
    let edits = String(decoding:try JSONEncoder().encode(ops),as:UTF8.self)
    #expect(throws:(any Error).self) { try snapshot.applying(edits,multiFile:true) }
    let refactor = try snapshot.applying(edits,multiFile:true,limit:32)
    #expect(refactor.files.count == 10)
    #expect(WebFiles.validPath("Models/CounterModel+snapshot.swift"))
}
