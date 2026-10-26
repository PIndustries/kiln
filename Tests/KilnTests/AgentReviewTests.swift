import Foundation
import Testing
import KilnKit
@testable import KilnSSH
@testable import KilnTerminal
@testable import KilnDevelopment

private func reviewJSON() throws -> String {
    let view = AgentFileReview(worker:"12345678-0000-0000-0000-000000000000",status:"conflict",files:["App.swift","Views/Page.swift"],path:"App.swift",base:"let old = 1",current:"let current = 2",proposed:"let proposed = 3",currentSHA256:"live-hash",proposalSHA256:"proposal-hash",conflict:true,diff:"--- a/App.swift\n+++ b/App.swift\n-let old = 1\n+let proposed = 3")
    return String(decoding:try JSONEncoder().encode(view),as:UTF8.self)
}
@Test func proposalReviewShowsColoredDiffAndSourceAndRequiresExplicitDraftStaging() throws {
    var ui = AgentReviewUI(module:"demo/web")
    ui.finish("[{\"worker\":\"12345678-0000-0000-0000-000000000000\",\"status\":\"conflict\",\"created\":0}]",status:0)
    guard case .read(let parts) = ui.handle(.enter,width:100,height:25) else { Issue.record("Review did not open proposal"); return }
    #expect(parts == ["web","agent-review","demo/web","12345678-0000-0000-0000-000000000000"])
    ui.finish(try reviewJSON(),status:0)
    let frame = ui.render(width:100,height:25,theme:TerminalTheme())
    #expect(frame.contains("CONFLICT")); #expect(frame.contains("\u{1b}[38;5;82m+let proposed")); #expect(frame.contains("\u{1b}[38;5;203m-let old"))
    _ = ui.handle(.tab,width:100,height:25)
    #expect(ui.render(width:100,height:25,theme:TerminalTheme()).contains("current"))
    #expect(ui.handle(.text("s"),width:100,height:25) == nil)
    #expect(ui.render(width:100,height:25,theme:TerminalTheme()).contains("local draft?"))
    _ = ui.handle(.escape,width:100,height:25)
    #expect(ui.handle(.text("s"),width:100,height:25) == nil)
    guard case .stage(let command) = ui.handle(.enter,width:100,height:25) else { Issue.record("Stage confirmation did not create draft request"); return }
    #expect(command == ["web","agent-stage","demo/web","12345678-0000-0000-0000-000000000000","App.swift","live-hash","proposal-hash"])
}
@Test func proposalStagingUsesCurrentFileAsDraftBaseAndPreservesDirtyBuffers() throws {
    var ui = WorkspaceUI(module:"demo/web")
    let browse: [String:Any] = ["tree":["version":"workspace","editable":true,"projectRoot":true,"files":[["path":"App.swift","sha256":"live-hash","bytes":15]]],"file":["file":"App.swift","source":"let current = 2","sha256":"live-hash","version":"workspace"]]
    ui.finish(text:String(decoding:try JSONSerialization.data(withJSONObject:browse),as:UTF8.self),status:0)
    #expect(ui.handle(.agentReview,width:100,height:25)?.contains("'agents'") == true)
    ui.finish(text:"[{\"worker\":\"12345678-0000-0000-0000-000000000000\",\"status\":\"conflict\",\"created\":0}]",status:0)
    _ = ui.handle(.enter,width:100,height:25); ui.finish(text:try reviewJSON(),status:0)
    #expect(ui.contextJSON?.contains("reviewWorker") == true)
    let context = try JSONDecoder().decode([String:String].self,from:Data(ui.contextJSON!.utf8))
    #expect(context["unsaved"] == "false")
    _ = ui.handle(.text("s"),width:100,height:25)
    #expect(ui.handle(.enter,width:100,height:25)?.contains("'agent-stage'") == true)
    var result = SwiftIDEResult(action:"agent-draft",message:"local only")
    result.renameFiles = ["App.swift":SwiftIDERenameFile(source:"let current = 2",sha256:"live-hash",text:"let proposed = 3")]
    ui.finish(text:String(decoding:try JSONEncoder().encode(result),as:UTF8.self),status:0)
    #expect(ui.hasUnsavedEdits)
    #expect(ui.render(width:100,height:25,theme:TerminalTheme()).contains("staged locally"))
    #expect(ui.handle(.agentReview,width:100,height:25) == nil)
    #expect(ui.hasUnsavedEdits)
}
@Test func proposalShortcutDoesNotReplaceBuildAndDefinitionKeys() {
    var keys = TerminalKeys()
    #expect(keys.feed([16]) == [.agentReview])
    #expect(keys.feed(Array("\u{1b}[23~\u{1b}[24~".utf8)) == [.build,.definition])
}

@Test func independentWorkspaceLaneAllowsProposalInspectionButNeverPublication() {
    #expect(workspaceReadAllowed(["web","agents","demo/web"]))
    #expect(workspaceReadAllowed(["web","agent-review","demo/web","worker"]))
    #expect(workspaceReadAllowed(["web","agent-stage","demo/web","worker","App.swift","current","proposal"]))
    #expect(!workspaceReadAllowed(["web","apply","demo/web","[]"]))
    #expect(!workspaceReadAllowed(["web","restore","demo/web","change"]))
    #expect(!workspaceReadAllowed(["app","deploy","manifest"]))
    #expect(!workspaceReadAllowed(["web","agent-stage","demo/web","worker"]))
}
