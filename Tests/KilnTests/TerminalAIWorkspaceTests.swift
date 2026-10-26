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

@Test func providerHeaderShowsSelectedProfileAndRejectsControlCharacters() {
    var ui = sidebarUI(snapshot: AIWorkspaceSnapshot(provider: AIProviderSnapshot(provider: "ollama", profile: "local")))
    #expect(ui.render().contains("selected: Ollama"))
    #expect(ui.render().contains("Ollama daemon / ollama / local"))
    ui.updateAIWorkspace(AIWorkspaceSnapshot(provider: AIProviderSnapshot(provider: "erebine", profile: "work")))
    #expect(ui.render().contains("selected: Erebine"))
    #expect(ui.render().contains("API credential / erebine / work"))
    #expect(!ui.render().contains("selected: Ollama"))
    let hostile = AIProviderSnapshot(provider: "\u{1b}[2J", profile: "\u{1b}[2J")
    #expect(hostile.label == "unknown / invalid")
}

@Test func providerStaysVisibleAcrossDashboardCommandsChatAndNarrowTasks() {
    var ui = KilnTerminal()
    for width in [50, 80, 120] {
        ui.resize(width: width, height: 24)
        ui.updateAIWorkspace(AIWorkspaceSnapshot(provider: AIProviderSnapshot(provider: "chatgpt", profile: "chatgpt", model: "gpt-6.1-sol")))
        #expect(ui.render().contains("Selected AI: ChatGPT | ChatGPT plan"))
        _ = ui.handle(.text("`"))
        #expect(ui.render().contains("COMMAND DRAWER"))
        #expect(ui.render().contains("Selected AI: ChatGPT | ChatGPT plan"))
        _ = ui.handle(.text("`"))
        _ = ui.handle(.text("7"))
        #expect(ui.render().contains("selected: ChatGPT [ready]"))
        #expect(ui.render().contains("Model: gpt-6.1-sol"))
        _ = ui.handle(.tab)
        #expect(ui.render().contains("AI: ChatGPT | ChatGPT plan"))
        _ = ui.handle(.escape)
        _ = ui.handle(.escape)
    }
    ui.updateAIWorkspace(AIWorkspaceSnapshot(provider: AIProviderSnapshot(provider: "erebine", profile: "work", model: "erebine/co-engineer")))
    #expect(ui.render().contains("Selected AI: Erebine | API credential"))
    #expect(!ui.render().contains("ChatGPT plan"))
    ui.updateAIWorkspace(AIWorkspaceSnapshot(error: "Access revoked"))
    #expect(ui.render().contains("Selected AI: not configured"))
    #expect(!ui.render().contains("Erebine"))
}

@Test func sidebarHomeSelectsApprovalAfterBackgroundTasksPreserveTheirSelection() {
    var ui = sidebarUI(width:80)
    _ = ui.handle(.tab); _ = ui.handle(.end)
    ui.updateAIWorkspace(AIWorkspaceSnapshot(tasks:sidebarSnapshot().tasks))
    ui.updateAIWorkspace(sidebarSnapshot())
    _ = ui.handle(.home)
    #expect(ui.handle(.enter).isEmpty)
    #expect(ui.render().contains("REVIEW OPERATION"))
    #expect(ui.render().contains(approvalID))
    #expect(!ui.busy)
}
