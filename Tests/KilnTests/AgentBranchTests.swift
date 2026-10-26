import Foundation
import Testing
import KilnKit
@testable import KilnDevelopment

private func branchFixture(_ root: URL) async throws -> (WebDevelopment,WebProjectConfiguration) {
    let source = root.appendingPathComponent("source")
    try WebFiles(files:["App.swift":Data("original".utf8),"Models/Value.swift":Data("model".utf8)]).writeSources(at:source)
    let input = root.appendingPathComponent("object")
    try KilnStateFile.write(Data("trusted".utf8),to:input)
    let recipe: [String:Any] = ["schemaVersion":1,"compiler":"/usr/bin/false","builder":"/usr/bin/false","launcher":"/usr/bin/false","arguments":[],"objects":[input.path],"readRoots":[root.path],"runtimeLibraries":[],"inputDigests":[input.path:WebIsolation.digest(Data("trusted".utf8))],"projectFiles":true]
    let sdk = root.appendingPathComponent("sdk.json")
    try KilnStateFile.write(JSONSerialization.data(withJSONObject:recipe),to:sdk)
    let config = WebProjectConfiguration(schemaVersion:1,module:"demo/web",source:source.appendingPathComponent("App.swift").path,sdk:sdk.path,publicOrigin:"http://127.0.0.1:18085",ingressPort:18085,workerPorts:[18084,18086],autoPublish:true,root:source.path)
    let dev = WebDevelopment(directory:root)
    _ = try await dev.register(data:JSONEncoder().encode(config),target:ApplicationManifest(application:"demo",name:"web",version:"1",executable:"/usr/bin/false",ingressPort:18085))
    return (dev,config)
}
private func branchRoot() throws -> URL {
    let url = URL(fileURLWithPath:WebIsolation.canonical(FileManager.default.temporaryDirectory.path)).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]); return url
}
@Test func agentMergePreservesIndependentFilesAndRejectsOverlappingCreatesDeletesAndEdits() throws {
    let base = WebFiles(files:["App.swift":Data("one".utf8),"A.txt":Data("a".utf8)])
    var proposal = base; proposal.files["App.swift"] = Data("two".utf8)
    var current = base; current.files["A.txt"] = Data("b".utf8)
    let merged = try WebDevelopment.mergeAgent(base:base,proposal:proposal,current:current)
    #expect(merged.files["A.txt"] == current.files["A.txt"])
    #expect(merged.files["App.swift"] == proposal.files["App.swift"])
    current.files["App.swift"] = Data("three".utf8)
    #expect(throws:(any Error).self) { try WebDevelopment.mergeAgent(base:base,proposal:proposal,current:current) }
    proposal = base; proposal.files.removeValue(forKey:"A.txt")
    #expect(throws:(any Error).self) { try WebDevelopment.mergeAgent(base:base,proposal:proposal,current:current) }
    proposal = base; proposal.files["New.txt"] = Data("agent".utf8)
    current = base; current.files["New.txt"] = Data("other".utf8)
    #expect(throws:(any Error).self) { try WebDevelopment.mergeAgent(base:base,proposal:proposal,current:current) }
}
@Test func agentSnapshotsAreOwnerScopedRetainedAndConflictsNeverPublish() async throws {
    guard WebIsolation.supported else { return }
    let root = try branchRoot(); defer { try? FileManager.default.removeItem(at:root) }
    let (dev,config) = try await branchFixture(root), worker = UUID().uuidString.lowercased()
    let initial = try await dev.agentSnapshot(module:"demo/web",worker:worker,owner:"one")
    try KilnStateFile.write(Data("external".utf8),to:URL(fileURLWithPath:config.source))
    #expect(try await dev.agentSnapshot(module:"demo/web",worker:worker,owner:"one") == initial)
    #expect(try await dev.agentSnapshot(module:"demo/web",worker:worker,owner:"two") != initial)
    let edits = "[{\"before\":\"original\",\"after\":\"agent\"}]"
    _ = try await dev.prepareAgent(module:"demo/web",worker:worker,owner:"one",edits:edits,limit:8)
    await #expect(throws:(any Error).self) {
        try await dev.integrateAgent(module:"demo/web",worker:worker,owner:"one",edits:edits,validate:{},publish:{ _,_ in Issue.record("Unvalidated proposal published");return "bad" })
    }
    try await dev.validateAgent(module:"demo/web",worker:worker,owner:"one",edits:edits)
    await #expect(throws:(any Error).self) {
        try await dev.integrateAgent(module:"demo/web",worker:worker,owner:"one",edits:edits,validate:{},publish:{ _,_ in Issue.record("Conflict published");return "bad" })
    }
    #expect(try await dev.agentHistory(module:"demo/web",owner:"one").contains("conflict"))
    #expect(try await dev.agentDiff(module:"demo/web",worker:worker,owner:"one").contains("+agent"))
    let restarted = WebDevelopment(directory:root)
    #expect(try await restarted.agentFiles(module:"demo/web",worker:worker,owner:"one",proposed:true).contains("agent"))
    await #expect(throws:(any Error).self) { try await restarted.integrateAgent(module:"demo/web",worker:worker,owner:"one",edits:edits,validate:{},publish:{ _,_ in Issue.record("Restart replayed conflict");return "bad" }) }
    #expect(try String(contentsOfFile:config.source,encoding:.utf8) == "external")
}
private actor BranchGate {
    var entered = false
    var released = false
    func arrive() async throws { entered = true; while !released { try await Task.sleep(nanoseconds:10_000_000) } }
    func release() { released = true }
}
@Test func agentQueueIntegratesDisjointChangesInOrderAndRetainsCancelledProposals() async throws {
    guard WebIsolation.supported else { return }
    let root = try branchRoot(); defer { try? FileManager.default.removeItem(at:root) }
    let (dev,config) = try await branchFixture(root), first = UUID().uuidString.lowercased(), second = UUID().uuidString.lowercased(), cancelled = UUID().uuidString.lowercased()
    let edits = ["[{\"before\":\"original\",\"after\":\"first\"}]","[{\"path\":\"Models/Value.swift\",\"before\":\"model\",\"after\":\"second\"}]"]
    for (id,edit) in [(first,edits[0]),(second,edits[1]),(cancelled,edits[1])] {
        _ = try await dev.prepareAgent(module:"demo/web",worker:id,owner:"one",edits:edit,limit:8)
        try await dev.validateAgent(module:"demo/web",worker:id,owner:"one",edits:edit)
    }
    let gate = BranchGate()
    let a = Task { try await dev.integrateAgent(module:"demo/web",worker:first,owner:"one",edits:edits[0],validate:{},publish:{ files,digest in
        try await gate.arrive()
        let current = try WebFiles.read(config); #expect(try current.digest == digest)
        try WebFiles(files:files).install(config,expected:current); return "first receipt"
    }) }
    for _ in 0..<200 { if await gate.entered { break }; try await Task.sleep(nanoseconds:10_000_000) }
    #expect(await gate.entered)
    let b = Task { try await dev.integrateAgent(module:"demo/web",worker:second,owner:"one",edits:edits[1],validate:{},publish:{ files,digest in
        let current = try WebFiles.read(config); #expect(try current.digest == digest)
        #expect(String(decoding:files["App.swift"]!,as:UTF8.self) == "first")
        try WebFiles(files:files).install(config,expected:current); return "second receipt"
    }) }
    for _ in 0..<200 { if await dev.agentQueue.count == 2 { break }; try await Task.sleep(nanoseconds:10_000_000) }
    let c = Task { try await dev.integrateAgent(module:"demo/web",worker:cancelled,owner:"one",edits:edits[1],validate:{},publish:{ _,_ in Issue.record("Cancelled proposal published"); return "bad" }) }
    for _ in 0..<200 { if await dev.agentQueue.count == 3 { break }; try await Task.sleep(nanoseconds:10_000_000) }
    #expect(await dev.agentQueue.count == 3)
    let restarted = WebDevelopment(directory:root)
    #expect(try await restarted.agentHistory(module:"demo/web",owner:"one").contains("interrupted-needs-inspection"))
    await #expect(throws:(any Error).self) {
        try await restarted.integrateAgent(module:"demo/web",worker:second,owner:"one",edits:edits[1],validate:{},publish:{ _,_ in Issue.record("Restart replayed queued integration"); return "bad" })
    }
    c.cancel(); do { _ = try await c.value; Issue.record("Cancellation ignored") } catch {}
    #expect(try await dev.agentHistory(module:"demo/web",owner:"one").contains("needs-inspection"))
    await gate.release()
    #expect(try await a.value == "first receipt"); #expect(try await b.value == "second receipt")
    #expect(try String(contentsOfFile:config.source,encoding:.utf8) == "first")
    #expect(try WebFiles.read(config).files["Models/Value.swift"] == Data("second".utf8))
    #expect(await dev.agentQueue.isEmpty)
}

@Test func agentIntegrationRejectsSourceChangesBetweenMergeAndBuild() async throws {
    guard WebIsolation.supported else { return }
    let root = try branchRoot(); defer { try? FileManager.default.removeItem(at:root) }
    let (dev,config) = try await branchFixture(root)
    let current = try WebFiles.read(config)
    try KilnStateFile.write(Data("newer".utf8),to:URL(fileURLWithPath:config.source))
    let target = ApplicationManifest(application:"demo",name:"web",version:"1",executable:"/usr/bin/false",ingressPort:18085)
    do {
        _ = try await dev.change(module:"demo/web",owner:"one",edits:"[]",target:target,restoring:current.files,expectedSource:current.digest,progress:{ _ in },validate:{},deploy:{ _ in Issue.record("Stale merge deployed"); return "bad" })
        Issue.record("Stale merge accepted")
    } catch { #expect(String(describing:error).contains("Source changed before integration")) }
    #expect(try String(contentsOfFile:config.source,encoding:.utf8) == "newer")
}

private extension WebDevelopment {
    func occupyAgentTestCompiler(_ module: String) { busy.insert(module) }
}
@Test func waitingAgentValidationCancelsWithoutCompilingOrMarkingValidated() async throws {
    guard WebIsolation.supported else { return }
    let root = try branchRoot(); defer { try? FileManager.default.removeItem(at:root) }
    let (dev,_) = try await branchFixture(root), worker = UUID().uuidString.lowercased()
    await dev.occupyAgentTestCompiler("demo/web")
    let target = ApplicationManifest(application:"demo",name:"web",version:"1",executable:"/usr/bin/false",ingressPort:18085)
    let task = Task { try await dev.validateAgentChange(module:"demo/web",worker:worker,owner:"one",edits:"[{\"before\":\"original\",\"after\":\"agent\"}]",target:target,limit:8,progress:{ _ in },validate:{}) }
    for _ in 0..<200 { if await !dev.agentValidating.isEmpty { break }; try await Task.sleep(nanoseconds:10_000_000) }
    #expect(await !dev.agentValidating.isEmpty)
    task.cancel()
    do { _ = try await task.value; Issue.record("Waiting validation ignored cancellation") } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    #expect(await dev.agentValidating.isEmpty)
    let history = try await dev.agentHistory(module:"demo/web",owner:"one")
    let rows = try JSONDecoder().decode([AgentBranch].self,from:Data(history.utf8))
    #expect(rows.first?.status == "unvalidated")
    let jobs = (try? FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("web-development/jobs").path)) ?? []
    #expect(jobs.isEmpty)
}
