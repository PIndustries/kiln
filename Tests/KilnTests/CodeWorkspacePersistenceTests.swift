import Foundation
import Testing
import KilnKit
@testable import KilnDevelopment
@testable import KilnTerminal
@testable import KilnCommands

private func recoveryDirectory() throws -> URL {
    let root = URL(fileURLWithPath:WebIsolation.canonical(FileManager.default.temporaryDirectory.path)).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]); return root
}
private func recoveryBuffer(_ text: String = "struct Old {}") -> CodeWorkspaceBuffer {
    CodeWorkspaceBuffer(source:text,draft:"// unsaved\n"+text,sha256:WebIsolation.digest(Data(text.utf8)),cursor:11,offset:0,horizontal:0,isNew:false)
}
@Test func recoveryWorkspacesAreStableOwnerScopedAndNeverWriteApplicationSource() async throws {
    let root = try recoveryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
    let store = CodeWorkspaceStore(directory:root)
    let first = try await store.load(owner:"alice",module:"demo/web")
    var state = first.state; state.path = "Views/Header.swift"; state.buffers[state.path] = recoveryBuffer()
    state.vim = true; state.dividerShare = 7000
    let saved = try await store.save(owner:"alice",module:"demo/web",update:CodeWorkspaceSave(expectedRevision:first.revision,state:state))
    #expect(saved.revision == first.revision+1)
    let restarted = CodeWorkspaceStore(directory:root)
    #expect(try await restarted.load(owner:"alice",module:"demo/web") == saved)
    #expect(try await restarted.load(owner:"bob",module:"demo/web").id != saved.id)
    #expect(try await restarted.load(owner:"alice",module:"demo/other").id != saved.id)
    #expect(!FileManager.default.fileExists(atPath:root.appendingPathComponent("Views/Header.swift").path))
    let files = try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("code-workspaces"),includingPropertiesForKeys:nil).filter { $0.pathExtension == "json" }
    for file in files { #expect((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600) }
}
@Test func staleWorkspaceClientsCannotOverwriteEachOthersRecoveryBuffers() async throws {
    let root = try recoveryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
    let first = CodeWorkspaceStore(directory:root), second = CodeWorkspaceStore(directory:root)
    let initial = try await first.load(owner:"alice",module:"demo/web")
    var one = initial.state; one.buffers["App.swift"] = recoveryBuffer("struct First {}")
    let saved = try await first.save(owner:"alice",module:"demo/web",update:CodeWorkspaceSave(expectedRevision:0,state:one))
    var two = initial.state; two.buffers["App.swift"] = recoveryBuffer("struct Second {}")
    do { _ = try await second.save(owner:"alice",module:"demo/web",update:CodeWorkspaceSave(expectedRevision:0,state:two)); Issue.record("Stale client overwrote newer draft") } catch {}
    #expect(try await first.load(owner:"alice",module:"demo/web") == saved)
    let copies = try await second.conflicts(owner:"alice",module:"demo/web")
    #expect(copies.count == 1)
    #expect(try await second.conflicts(owner:"bob",module:"demo/web").isEmpty)
    let restored = try await second.recover(owner:"alice",module:"demo/web",conflict:copies[0],expectedRevision:saved.revision)
    #expect(restored.state == two)
}
@Test func recoveryRejectsForgedBasesAndUnregisteredPaths() async throws {
    let root = try recoveryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
    let store = CodeWorkspaceStore(directory:root), initial = try await store.load(owner:"alice",module:"demo/web")
    var state = initial.state; var buffer = recoveryBuffer(); buffer.sha256 = String(repeating:"0",count:64); state.buffers["App.swift"] = buffer
    do { _ = try await store.save(owner:"alice",module:"demo/web",update:CodeWorkspaceSave(expectedRevision:0,state:state)); Issue.record("Forged base accepted") } catch {}
    state = initial.state; state.path = "../private.swift"
    do { _ = try await store.save(owner:"alice",module:"demo/web",update:CodeWorkspaceSave(expectedRevision:0,state:state)); Issue.record("Escaped path accepted") } catch {}
    #expect(try await store.load(owner:"alice",module:"demo/web").revision == 0)
}
private func recoveryBrowse(record: CodeWorkspaceRecord, text: String = "struct Old {}", worker: AIWorkSnapshot? = nil) throws -> String {
    var object: [String:Any] = ["tree":["version":"workspace","editable":true,"projectRoot":true,"files":[["path":"App.swift","sha256":WebIsolation.digest(Data(text.utf8)),"bytes":text.utf8.count]]],"file":["file":"App.swift","sha256":WebIsolation.digest(Data(text.utf8)),"source":text,"version":"workspace"],"workspace":try JSONSerialization.jsonObject(with:JSONEncoder().encode(record))]
    if let worker { object["worker"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(worker)) }
    return String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self)
}
@Test func editorRestoresDraftAndSettingsWithoutPublishingAndKeepsNewTypingAfterAnAck() throws {
    var record = CodeWorkspaceRecord(module:"demo/web")
    record.state.buffers["App.swift"] = recoveryBuffer(); record.state.vim = true; record.state.treeFocus = false; record.state.dividerShare = 7200
    var ui = WorkspaceUI(module:"demo/web"); ui.finish(text:try recoveryBrowse(record:record),status:0)
    #expect(ui.hasUnsavedEdits)
    #expect(ui.render(width:120,height:30,theme:TerminalTheme()).contains("unsaved"))
    #expect(ui.takeRestoredDivider() == 7200)
    #expect(ui.takeRestoredDivider() == nil)
    _ = ui.handle(.text("i"),width:120,height:30); _ = ui.handle(.text("new"),width:120,height:30)
    let effect = ui.checkpoint(dividerShare:7200), command = try #require(effect)
    let parts = try KilnCommands.tokenize(command)
    #expect(Array(parts.prefix(3)) == ["web","workspace-save","demo/web"])
    let update = try JSONDecoder().decode(CodeWorkspaceSave.self,from:Data(parts[3].utf8))
    _ = ui.handle(.text("er"),width:120,height:30)
    record.revision = 1; record.state = update.state
    ui.finishCheckpoint(text:String(decoding:try JSONEncoder().encode(record),as:UTF8.self),status:0)
    #expect(ui.checkpoint(dividerShare:7200) != nil)
}
@Test func staleSourceRecoveryRetainsTheOriginalBaseAndReattachesWorkerFromLoad() throws {
    var record = CodeWorkspaceRecord(module:"demo/web"); record.state.buffers["App.swift"] = recoveryBuffer()
    let worker = AIWorkSnapshot(id:UUID().uuidString.lowercased(),prompt:"Inspect app",state:"running")
    var ui = WorkspaceUI(module:"demo/web"); ui.finish(text:try recoveryBrowse(record:record,text:"struct Changed {}",worker:worker),status:0)
    #expect(ui.hasUnsavedEdits)
    #expect(ui.render(width:120,height:30,theme:TerminalTheme()).contains("different source base"))
    #expect(ui.takeWorkerToAttach()?.id == worker.id)
    #expect(ui.takeWorkerToAttach() == nil)
    _ = ui.handle(.eof,width:120,height:30); _ = ui.handle(.down,width:120,height:30)
    let action = ui.handle(.enter,width:120,height:30), command = try #require(action)
    let parts = try KilnCommands.tokenize(command), edits = try JSONDecoder().decode([[String:String]].self,from:Data(parts[3].utf8))
    #expect(edits[0]["sha256"] == WebIsolation.digest(Data("struct Old {}".utf8)))
}
@Test func workspaceDiscardAfterAnInflightSaveIsPersistedBeforeClosing() throws {
    var record = CodeWorkspaceRecord(module:"demo/web")
    var ui = KilnTerminal(); ui.resize(width:160,height:35)
    ui.update([ModuleSnapshot(application:"demo",name:"web",version:"1",state:"running",pid:42)])
    _ = ui.handle(.enter)
    for _ in 0..<8 { _ = ui.handle(.down) }
    _ = ui.handle(.enter); ui.finishWorkspace(text:try recoveryBrowse(record:record),status:0)
    _ = ui.handle(.text("e")); _ = ui.handle(.text("// temporary draft\n"))
    let firstCheckpoint = ui.checkpointCodeWorkspace()
    guard case .workspaceSave(let command) = try #require(firstCheckpoint) else { Issue.record("Missing checkpoint"); return }
    let parts = try KilnCommands.tokenize(command)
    let update = try JSONDecoder().decode(CodeWorkspaceSave.self,from:Data(parts[3].utf8))
    #expect(!update.state.buffers.isEmpty)
    // Discard and close before the acknowledgement comes back.
    _ = ui.handle(.escape); _ = ui.handle(.down); _ = ui.handle(.enter); _ = ui.handle(.escape)
    #expect(ui.checkpointCodeWorkspace() == nil)
    record.revision = 1; record.state = update.state
    ui.finishWorkspaceSave(text:String(decoding:try JSONEncoder().encode(record),as:UTF8.self),status:0)
    let finalCheckpoint = ui.checkpointCodeWorkspace()
    guard case .workspaceSave(let clean) = try #require(finalCheckpoint) else { Issue.record("Discard not checkpointed"); return }
    let cleanParts = try KilnCommands.tokenize(clean)
    let cleanUpdate = try JSONDecoder().decode(CodeWorkspaceSave.self,from:Data(cleanParts[3].utf8))
    #expect(cleanUpdate.expectedRevision == 1)
    #expect(cleanUpdate.state.buffers.isEmpty)
}
@Test func workspaceRecoveryRejectsSymlinkedAndPublicStorage() async throws {
    let root = try recoveryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
    let outside = root.appendingPathComponent("outside",isDirectory:true)
    try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    let directory = root.appendingPathComponent("code-workspaces",isDirectory:true)
    try FileManager.default.createSymbolicLink(at:directory,withDestinationURL:outside)
    let store = CodeWorkspaceStore(directory:root)
    do { _ = try await store.load(owner:"alice",module:"demo/web"); Issue.record("Symlinked recovery directory accepted") } catch {}
    #expect(try FileManager.default.contentsOfDirectory(atPath:outside.path).isEmpty)
    try FileManager.default.removeItem(at:directory)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o755])
    do { _ = try await store.load(owner:"alice",module:"demo/web"); Issue.record("Public recovery directory accepted") } catch {}
}
