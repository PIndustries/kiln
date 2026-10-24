import Foundation
import Testing
import KilnKit
import KilnAI
import KilnTerminal

private let firstSource = AIProviderSnapshot(provider: "erebine", profile: "first", model: "Sparrow-v1")
private let secondSource = AIProviderSnapshot(provider: "chatgpt", profile: "second", model: "Orion-v2")
private func sourceUI(width: Int = 120) -> KilnTerminal {
    var ui = KilnTerminal(); ui.resize(width: width, height: 40)
    ui.updateAIWorkspace(AIWorkspaceSnapshot(provider: firstSource))
    _ = ui.handle(.text("7")); return ui
}
private func sourceRequest(_ text: String, _ ui: inout KilnTerminal) -> [TerminalEffect] {
    _ = ui.handle(.text(text)); return ui.handle(.enter)
}
private final class ProviderOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AIProviderSnapshot] = []
    private var beforeCompletion = false
    func record(_ event: AIProgress) {
        if case .provider(let source) = event { lock.withLock { values.append(source) } }
    }
    func completing() { lock.withLock { beforeCompletion = values.count == 1 } }
    func snapshot() -> ([AIProviderSnapshot], Bool) { lock.withLock { (values, beforeCompletion) } }
}

@Test func assistantBindsProviderFromAdmittedConfigurationBeforeCompletion() async throws {
    let order = ProviderOrder()
    let assistant = KilnAssistant { _, _, _, _ in order.completing(); return AIMessage(role: "assistant", content: "answer") }
    let config = AIConfiguration(baseURL: "http://127.0.0.1:11434", model: "ActualCase-v1", secret: "", provider: .ollama, profile: "actual")
    _ = try await assistant.ask("question", session: "fixture", configuration: config, key: "", modules: [], context: "fixture", knowledge: nil, progress: { order.record($0) }) { _, _ in "unused" }
    let (sources, before) = order.snapshot()
    #expect(before)
    #expect(sources == [AIProviderSnapshot(provider: "ollama", profile: "actual", model: "ActualCase-v1")])
}

@Test func responseSourceSurvivesSelectedProfileChangesDuringStreaming() {
    for width in [50, 80, 120] {
        var ui = sourceUI(width: width)
        _ = sourceRequest("question", &ui)
        ui.progress(.provider(firstSource))
        ui.updateAIWorkspace(AIWorkspaceSnapshot(provider: secondSource))
        // Repeated or late provider events cannot overwrite the admitted source.
        ui.progress(.provider(secondSource))
        ui.progress(.snapshot(String(repeating: "Long streamed line\n", count: 100)))
        #expect(ui.render().contains("selected: ChatGPT"))
        #expect(ui.render().contains("via Erebine / first"))
        ui.finish(text: "Completed by the first provider.", status: 0)
        #expect(ui.render().contains("KILN / Erebine / first / Sparrow-v1"))
        #expect(ui.render().contains("Model: Orion-v2"))
    }
}

@Test func localRepliesDoNotInheritProviderAndLaterAnswersKeepTheirOwnSource() {
    var ui = sourceUI()
    _ = sourceRequest("first question", &ui); ui.progress(.provider(firstSource)); ui.finish(text: "First answer", status: 0)
    _ = sourceRequest("/context", &ui); ui.finish(text: "Local context report", status: 0)
    _ = sourceRequest("second question", &ui); ui.progress(.provider(secondSource)); ui.finish(text: "Second answer", status: 0)
    let frame = ui.render()
    #expect(frame.components(separatedBy: "KILN / Erebine / first").count == 2)
    #expect(frame.components(separatedBy: "KILN / ChatGPT / second").count == 2)
    #expect(frame.contains("Local context report"))
}

@Test func requestErrorsRetainTheirSourceWithoutStampingLaterLocalErrors() {
    var ui = sourceUI()
    _ = sourceRequest("question", &ui); ui.progress(.provider(firstSource)); ui.finish(text: "Provider request failed", status: 1)
    ui.progress(.provider(secondSource)) // Idle progress cannot start attribution.
    _ = sourceRequest("/deny missing", &ui); ui.finish(text: "Unknown proposal", status: 1)
    let frame = ui.render()
    #expect(frame.components(separatedBy: "ERROR / Erebine / first").count == 2)
    #expect(!frame.contains("ERROR / ChatGPT / second"))
    #expect(frame.contains("Unknown proposal"))
}
