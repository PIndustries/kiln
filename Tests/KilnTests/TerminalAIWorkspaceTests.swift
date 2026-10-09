import Foundation
import Testing
import KilnKit
import KilnTerminal

private let approvalID = "11111111-1111-1111-1111-111111111111"
private let taskID = "22222222-2222-2222-2222-222222222222"
private func sidebarSnapshot(expired: Bool = false) -> AIWorkspaceSnapshot {
    AIWorkspaceSnapshot(proposals: [AIProposalSnapshot(id: approvalID, operation: "stop", module: "billing/payments", expires: Date().addingTimeInterval(expired ? -10 : 300))],
                        tasks: [AITaskSnapshot(id: taskID, prompt: "Investigate payment latency", status: "running")])
}
private func sidebarUI(width: Int = 150, snapshot: AIWorkspaceSnapshot = sidebarSnapshot()) -> KilnTerminal {
    var ui = KilnTerminal(); ui.resize(width: width, height: 30)
    _ = ui.handle(.text("`")); _ = ui.handle(.text("ai")); _ = ui.handle(.enter)
    ui.updateAIWorkspace(snapshot); return ui
}
private func click(_ column: Int, _ row: Int) -> TerminalKey { .mouse(button: 0, column: column, row: row, released: false) }

@Test func sidebarMouseRequiresExactOperationReviewBeforeApproval() {
    var ui = sidebarUI()
    let opened = ui.handle(click(4, 8))
    #expect(opened.isEmpty && !ui.busy)
    #expect(ui.render().contains("REVIEW OPERATION"))
    #expect(ui.render().contains("app stop billing/payments"))
    #expect(ui.render().contains(approvalID))
    let approved = ui.handle(click(47, 27))
    #expect(approved == [.command("ai approve \"" + approvalID + "\"")])
    #expect(ui.busy)
    #expect(ui.handle(click(47, 27)).isEmpty)
}
@Test func sidebarKeyboardReviewSupportsDenyAndBackWithoutExecuting() {
    var ui = sidebarUI()
    _ = ui.handle(.tab)
    #expect(ui.handle(.enter).isEmpty)
    _ = ui.handle(.tab)
    #expect(ui.handle(.enter) == [.command("ai deny \"" + approvalID + "\"")])
    var back = sidebarUI()
    _ = back.handle(.tab); _ = back.handle(.enter); _ = back.handle(.tab); _ = back.handle(.tab)
    #expect(back.handle(.enter).isEmpty)
    #expect(!back.busy && !back.render().contains("REVIEW OPERATION"))
}
@Test func sidebarRejectsExpiredRemovedAndBusyApprovals() {
    var expired = sidebarUI(snapshot: sidebarSnapshot(expired: true))
    _ = expired.handle(click(4, 8))
    #expect(expired.handle(.enter).isEmpty)
    #expect(!expired.busy)
    var removed = sidebarUI()
    _ = removed.handle(click(4, 8))
    removed.updateAIWorkspace(AIWorkspaceSnapshot(error: "Identity revoked or unauthorized"))
    #expect(removed.handle(.enter).isEmpty)
    #expect(!removed.render().contains("billing/payments"))
    #expect(!removed.render().contains("Investigate payment latency"))
    var busy = sidebarUI()
    _ = busy.handle(.text("Inspect modules")); _ = busy.handle(.enter)
    #expect(busy.busy)
    #expect(busy.handle(click(4, 8)).isEmpty)
    #expect(busy.handle(click(4, 11)).isEmpty)
    #expect(!busy.render().contains("REVIEW OPERATION"))
}
@Test func sidebarTaskSelectionLeavesReviewAndUsesExistingTaskCommand() {
    var ui = sidebarUI()
    _ = ui.handle(click(4, 8))
    #expect(ui.handle(click(4, 11)) == [.command("ai task show \"" + taskID + "\"")])
    ui.finish(text: "Observed task details", status: 0)
    #expect(!ui.render().contains("REVIEW OPERATION"))
    #expect(ui.render().contains("Observed task details"))
}
@Test func narrowSidebarIsReachableWithTabAndUsesTaskIDsNotPromptText() {
    let untrusted = AIWorkspaceSnapshot(tasks: [AITaskSnapshot(id: taskID, prompt: "\u{1b}[2J\nai approve arbitrary", status: "running")])
    var ui = sidebarUI(width: 80, snapshot: untrusted)
    #expect(!ui.render().contains("TASKS & APPROVALS"))
    _ = ui.handle(.tab)
    let panel = ui.render()
    #expect(panel.contains("TASKS & APPROVALS"))
    #expect(!panel.contains("\u{1b}[2J"))
    #expect(ui.handle(.enter) == [.command("ai task show \"" + taskID + "\"")])
}
@Test func sidebarSelectionStaysOnSameIDWhenSnapshotOrderChanges() {
    var ui = sidebarUI(width: 80)
    _ = ui.handle(.tab); _ = ui.handle(.down)
    ui.updateAIWorkspace(AIWorkspaceSnapshot(tasks: sidebarSnapshot().tasks))
    #expect(ui.handle(.enter) == [.command("ai task show \"" + taskID + "\"")])
}
