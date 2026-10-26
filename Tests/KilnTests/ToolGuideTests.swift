import Foundation
import Testing
import KilnKit
@testable import KilnAI

private func guideCall(_ name: String, _ args: [String:String]) throws -> AIMessage {
    let arguments = String(decoding: try JSONEncoder().encode(args), as: UTF8.self)
    let data = try JSONSerialization.data(withJSONObject: ["id":UUID().uuidString,"type":"function","function":["name":name,"arguments":arguments]])
    return AIMessage(role: "assistant", content: nil, tool_calls: [try JSONDecoder().decode(AIToolCall.self, from: data)])
}
@Test func toolDiscoveryReflectsThisTurnsActualGrantAndContainsNoUnavailableCodingGuide() async throws {
    let ai = KilnAssistant { _, _, messages, tools in
        if let last = messages.last, last.role == "tool" {
            #expect(last.content?.contains("system_status(") == true)
            #expect(last.content?.contains("update_web_source(") == false)
            #expect(last.content?.contains("KILNWEB GUIDE") == false)
            #expect(!tools.contains { KilnAssistant.webToolNames.contains($0.function.name) })
            return AIMessage(role: "assistant", content: "Discovered permitted tools")
        }
        return try guideCall("tool_help", ["topic":"all"])
    }
    let configuration = AIConfiguration(baseURL: "http://127.0.0.1:11434", model: "fixture", secret: "", provider: .ollama)
    let result = try await ai.ask("What can you manage?", session: "viewer", configuration: configuration, key: "", modules: [], context: "", knowledge: nil, allowProposals: false) { _, _ in Issue.record("Local help delegated outside assistant"); return "" }
    #expect(result.contains("Discovered"))
}
private actor ValidationGuideCounter {
    var validations = 0
    var publishes = 0
    func validate() throws -> String {
        validations += 1
        if validations == 1 { throw AIError.message("Validation failed: fix syntax") }
        return "Isolated compile passed; source unchanged"
    }
    func passedValidation() -> String { validations += 1; return "Isolated compile passed" }
    func publish() -> String { publishes += 1; return "Published controller receipt" }
}
@Test func aiCanLearnFrameworkCorrectValidationAndPublishOnceWithoutDelegatingToUser() async throws {
    let count = ValidationGuideCounter()
    let ai = KilnAssistant { _, _, messages, tools in
        guard let last = messages.last, last.role == "tool" else { return try guideCall("tool_help", ["topic":"web"]) }
        if last.content?.contains("KILNWEB GUIDE") == true {
            #expect(last.content?.contains("HTML.join") == true)
            #expect(tools.contains { $0.function.name == "validate_web_source" })
            return try guideCall("validate_web_source", ["module":"demo/web","edits":"broken proposal"])
        }
        if last.content?.contains("Validation failed") == true { return try guideCall("validate_web_source", ["module":"demo/web","edits":"corrected proposal"]) }
        #expect(last.content?.contains("Isolated compile passed") == true)
        return try guideCall("update_web_source", ["module":"demo/web","edits":"corrected proposal"])
    }
    let result = try await ai.ask("Change this site", session: "admin", configuration: AIConfiguration(baseURL: "http://127.0.0.1:11434", model: "fixture", secret: "", provider: .ollama), key: "", modules: [ModuleSnapshot(application: "demo", name: "web", version: "1", state: "running", pid: 42)], context: "", knowledge: nil, webChange: { _, _ in await count.publish() }, webValidation: { _, _ in try await count.validate() }) { _, _ in "" }
    #expect(result == "Published controller receipt")
    #expect(await count.validations == 2)
    #expect(await count.publishes == 1)
}

@Test func changedPublicationProposalMustPassItsOwnValidationBeforeAnyWrite() async throws {
    let count = ValidationGuideCounter()
    let ai = KilnAssistant { _,_,messages,_ in
        let turns = messages.filter { $0.role == "tool" }.count
        switch turns {
        case 0: return try guideCall("validate_web_source",["module":"demo/web","edits":"first proposal"])
        case 1: return try guideCall("update_web_source",["module":"demo/web","edits":"changed proposal"])
        case 2:
            #expect(messages.last?.content?.contains("No write was attempted") == true)
            return try guideCall("validate_web_source",["module":"demo/web","edits":"changed proposal"])
        default: return try guideCall("update_web_source",["module":"demo/web","edits":"changed proposal"])
        }
    }
    let result = try await ai.ask("Refactor",session:"validate-exact",configuration:AIConfiguration(baseURL:"http://127.0.0.1:11434",model:"fixture",secret:"",provider:.ollama),key:"",modules:[ModuleSnapshot(application:"demo",name:"web",version:"1",state:"running",pid:42)],context:"",knowledge:nil,webChange:{ _,edits in
        #expect(edits == "changed proposal")
        #expect(await count.validations == 2)
        return await count.publish()
    },webValidation:{ _,_ in
        await count.passedValidation()
    }) { _,_ in "" }
    #expect(result == "Published controller receipt")
    #expect(await count.publishes == 1)
}

@Test func failedValidationCannotAuthorizePublication() async throws {
    let count = ValidationGuideCounter()
    let ai = KilnAssistant { _,_,messages,_ in
        let turns = messages.filter { $0.role == "tool" }.count
        if turns == 0 { return try guideCall("validate_web_source",["module":"demo/web","edits":"broken"] ) }
        if turns == 1 { return try guideCall("update_web_source",["module":"demo/web","edits":"broken"] ) }
        #expect(messages.last?.content?.contains("No write was attempted") == true)
        return AIMessage(role:"assistant",content:"No publication")
    }
    _ = try await ai.ask("Refactor",session:"failed-validation",configuration:AIConfiguration(baseURL:"http://127.0.0.1:11434",model:"fixture",secret:"",provider:.ollama),key:"",modules:[ModuleSnapshot(application:"demo",name:"web",version:"1",state:"running",pid:42)],context:"",knowledge:nil,webChange:{ _,_ in
        Issue.record("Failed validation authorized a write"); return await count.publish()
    },webValidation:{ _,_ in try await count.validate() }) { _,_ in "" }
    #expect(await count.publishes == 0)
}

@Test func validationAllowsJSONFormattingChangesWithoutChangingSourceStrings() async throws {
    let count = ValidationGuideCounter()
    let ai = KilnAssistant { _,_,messages,_ in
        let validated = messages.contains { $0.role == "tool" }
        return try guideCall(validated ? "update_web_source" : "validate_web_source",["module":"demo/web","edits":validated ? #"[ { "after": "new", "before": "old" } ]"# : #"[{"before":"old","after":"new"}]"#])
    }
    let result = try await ai.ask("Edit",session:"formatting",configuration:AIConfiguration(baseURL:"http://127.0.0.1:11434",model:"fixture",secret:"",provider:.ollama),key:"",modules:[ModuleSnapshot(application:"demo",name:"web",version:"1",state:"running",pid:42)],context:"",knowledge:nil,webChange:{ _,_ in await count.publish() },webValidation:{ _,_ in await count.passedValidation() }) { _,_ in "" }
    #expect(result == "Published controller receipt")
    #expect(await count.validations == 1)
    #expect(await count.publishes == 1)
}
