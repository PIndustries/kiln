import Foundation
import Testing
@testable import KilnCluster

private actor PeerCounter {
    var changes = 0
    func execute(_ operation: ClusterOperation, _ module: String?) -> String {
        if operation != .status { changes += 1 }
        return operation == .status ? "modules: demo/api running" : "\(operation.rawValue) \(module ?? "") count=\(changes)"
    }
    func count() -> Int { changes }
}

@Test func clusterTrustReceiptsAndNativeEncryptedTransport() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let counter = PeerCounter()
    let a = try KilnCluster(directory: folder.appendingPathComponent("a")) { operation, module in await counter.execute(operation, module) }
    let b = try KilnCluster(directory: folder.appendingPathComponent("b")) { operation, module in await counter.execute(operation, module) }
    let la = try await ClusterListener.start(host: "127.0.0.1", port: 0, key: a.privateKey, cluster: a)
    let lb = try await ClusterListener.start(host: "127.0.0.1", port: 0, key: b.privateKey, cluster: b)
    do {
        let bp = try await a.discover(host: "127.0.0.1", port: lb.channel.localAddress!.port!)
        let ap = try await b.discover(host: "127.0.0.1", port: la.channel.localAddress!.port!)
        #expect(bp.fingerprint == b.identity.fingerprint)
        #expect(ap.fingerprint == a.identity.fingerprint)
        #expect(await a.peers().isEmpty)
        await #expect(throws: (any Error).self) { _ = try await a.operate(peer: bp.fingerprint, operation: .start, module: "demo/api") }
        _ = try await a.accept(bp.fingerprint)
        // One-way adoption does not authorize A at B.
        await #expect(throws: (any Error).self) { _ = try await a.operate(peer: bp.fingerprint, operation: .status) }
        _ = try await b.accept(ap.fingerprint)
        let status = try await a.operate(peer: bp.fingerprint, operation: .status)
        #expect(status.state == "completed")
        #expect(status.output.contains("demo/api"))
        let id = UUID().uuidString.lowercased()
        let changed = try await a.operate(peer: bp.fingerprint, operation: .restart, module: "demo/api", requestID: id)
        #expect(changed.state == "completed")
        let duplicate = try await a.operate(peer: bp.fingerprint, operation: .restart, module: "demo/api", requestID: id)
        #expect(duplicate.output == changed.output)
        #expect(await counter.count() == 1)
        await #expect(throws: (any Error).self) { _ = try await a.operate(peer: bp.fingerprint, operation: .stop, module: "demo/api", requestID: id) }
        #expect(try await a.receipt(peer: bp.fingerprint, requestID: id).state == "completed")
        #expect(try await a.receipt(peer: bp.fingerprint, requestID: UUID().uuidString.lowercased()).state == "missing")
        #expect(await counter.count() == 1)
        #expect(try await a.operations().contains(id))
        // Native SSH host pin mismatch must fail before the request reaches B.
        let wrong = ClusterPeer(fingerprint: ap.fingerprint, publicKey: ap.publicKey, host: "127.0.0.1", port: lb.channel.localAddress!.port!, discoveredAt: Date())
        await #expect(throws: (any Error).self) { _ = try await ClusterTransport.execute(peer: wrong, key: a.privateKey, request: ClusterRequest(operation: .status)) }
        _ = try await b.revoke(ap.fingerprint)
        await #expect(throws: (any Error).self) { _ = try await a.operate(peer: bp.fingerprint, operation: .status) }
        #expect(await counter.count() == 1)
        _ = try await a.candidate(host: "127.0.0.2", port: 2223, publicKey: (try KilnCluster(directory: folder.appendingPathComponent("untrusted")) { _, _ in "" }).identity.publicKey)
        let extra = try KilnCluster(directory: folder.appendingPathComponent("extra")) { _, _ in "" }
        _ = try await a.candidate(host: "127.0.0.3", port: 2223, publicKey: extra.identity.publicKey)
        _ = try await a.accept(extra.identity.fingerprint)
        #expect(await a.candidates().count == 1)
        let reopened = try KilnCluster(directory: folder.appendingPathComponent("a")) { _, _ in "unused" }
        #expect(reopened.identity.fingerprint == a.identity.fingerprint)
        #expect(await reopened.peers().count == 2)
        #expect(await reopened.candidates().isEmpty)
        #expect(try await reopened.operations().contains(id))
    } catch { await la.stop(); await lb.stop(); throw error }
    await la.stop(); await lb.stop()
}

@Test func clusterRejectsExpiredForgedAndInterruptedMutationReplay() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let counter = PeerCounter()
    let a = try KilnCluster(directory: folder.appendingPathComponent("a")) { _, _ in "a" }
    let b = try KilnCluster(directory: folder.appendingPathComponent("b")) { operation, module in await counter.execute(operation, module) }
    _ = try await b.candidate(host: "127.0.0.1", port: 34567, publicKey: a.identity.publicKey)
    _ = try await b.accept(a.identity.fingerprint)
    let expired = ClusterRequest(issuedAt: Date(timeIntervalSinceNow: -600), operation: .restart, module: "demo/api")
    await #expect(throws: (any Error).self) { _ = try await b.receive(expired, from: a.identity.fingerprint) }
    let traversal = ClusterRequest(operation: .stop, module: "../api")
    await #expect(throws: (any Error).self) { _ = try await b.receive(traversal, from: a.identity.fingerprint) }
    let request = ClusterRequest(operation: .restart, module: "demo/api")
    let receipt: [String: Any] = ["peer": a.identity.fingerprint, "request": try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)), "response": ["id": request.id, "state": "started", "output": ""]]
    let path = folder.appendingPathComponent("b/cluster/receipts/\(request.id).json")
    try JSONSerialization.data(withJSONObject: receipt).write(to: path)
    let reopened = try KilnCluster(directory: folder.appendingPathComponent("b")) { operation, module in await counter.execute(operation, module) }
    #expect(try await reopened.receive(request, from: a.identity.fingerprint).state == "unconfirmed")
    #expect(await counter.count() == 0)
    // Untrusted advertisements cannot alter accepted addresses or become peers.
    _ = try await reopened.candidate(host: "192.0.2.99", port: 12345, publicKey: a.identity.publicKey)
    #expect(await reopened.peers().first?.host == "127.0.0.1")
}

@Test func clusterResponseLimitPreservesValidJSON() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let a = try KilnCluster(directory: folder.appendingPathComponent("a")) { _, _ in "" }
    let b = try KilnCluster(directory: folder.appendingPathComponent("b")) { _, _ in String(repeating: "\u{0}", count: 24000) }
    let listener = try await ClusterListener.start(host: "127.0.0.1", port: 0, key: b.privateKey, cluster: b)
    do {
        _ = try await a.candidate(host: "127.0.0.1", port: listener.channel.localAddress!.port!, publicKey: b.identity.publicKey)
        _ = try await a.accept(b.identity.fingerprint)
        _ = try await b.candidate(host: "127.0.0.1", port: 2223, publicKey: a.identity.publicKey)
        _ = try await b.accept(a.identity.fingerprint)
        let response = try await a.operate(peer: b.identity.fingerprint, operation: .status)
        #expect(response.state == "response-too-large")
        #expect(response.output.contains("64 KiB"))
    } catch { await listener.stop(); throw error }
    await listener.stop()
}

@Test func clusterOperationHistoryKeepsNewestUnconfirmedIDsVisible() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let cluster = try KilnCluster(directory: folder) { _, _ in "" }
    func seed(id: String, age: TimeInterval, completed: Bool) throws {
        let request = ClusterRequest(id: id, issuedAt: Date(timeIntervalSinceNow: -age), operation: .restart, module: "demo/api")
        var record: [String: Any] = ["peer": "SHA256:fixture", "request": try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))]
        if completed { record["response"] = ["id": id, "state": "completed", "output": "done"] }
        try JSONSerialization.data(withJSONObject: record).write(to: folder.appendingPathComponent("cluster/outbound/\(id).json"))
    }
    for index in 0..<105 { try seed(id: UUID().uuidString.lowercased(), age: Double(1000 + index), completed: true) }
    let newest = "00000000-0000-4000-8000-000000000001", oldest = "00000000-0000-4000-8000-000000000002"
    try seed(id: newest, age: 0, completed: false)
    try seed(id: oldest, age: 20000, completed: false)
    let output = try await cluster.operations()
    let lines = output.split(separator: "\n")
    #expect(output.contains("Showing 100 of 107"))
    #expect(output.contains("Older records remain"))
    #expect(lines.count == 101)
    #expect(lines[1].hasPrefix(newest))
    #expect(lines[2].hasPrefix(oldest))
}
