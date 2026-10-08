import Foundation
import Crypto
import NIOSSH
import KilnKit

public enum ClusterOperation: String, Codable, Sendable { case status, start, stop, restart }
public struct ClusterIdentity: Codable, Sendable {
    public let fingerprint: String
    public let publicKey: String
}
public struct ClusterPeer: Codable, Sendable {
    public let fingerprint: String
    public let publicKey: String
    public let host: String
    public let port: Int
    public let discoveredAt: Date
}
public struct ClusterRequest: Codable, Sendable {
    public let id: String
    public let issuedAt: Date
    public let operation: ClusterOperation
    public let module: String?
    public let receiptID: String?
    public init(id: String = UUID().uuidString.lowercased(), issuedAt: Date = Date(), operation: ClusterOperation, module: String? = nil, receiptID: String? = nil) {
        self.id = id; self.issuedAt = issuedAt; self.operation = operation; self.module = module; self.receiptID = receiptID
    }
}
public struct ClusterResponse: Codable, Sendable {
    public let id: String
    public let state: String
    public let output: String
    public init(id: String, state: String, output: String) { self.id = id; self.state = state; self.output = output }
}

/// Explicit peer trust and a narrowly typed control plane. There is no consensus,
/// automatic placement, arbitrary command execution or shared database here.
public actor KilnCluster {
    public typealias Executor = @Sendable (ClusterOperation, String?) async throws -> String
    public nonisolated let identity: ClusterIdentity
    let privateKey: NIOSSHPrivateKey
    private let directory: URL
    private let executor: Executor
    private struct Index: Codable { var candidates: [String: ClusterPeer] = [:]; var peers: [String: ClusterPeer] = [:] }
    private struct Receipt: Codable {
        var peer: String; var request: ClusterRequest; var response: ClusterResponse
    }
    private struct Outbound: Codable { let peer: String; let request: ClusterRequest; var response: ClusterResponse? }
    private var index: Index
    private var persistenceFault = false
    private var stopping = false
    private var starting = false
    private var shutdownTask: Task<Void, Never>?
    private var incomingRequests = 0
    private var outgoingRequests = 0
    private var sendingMutations: Set<String> = []
    private var reachability: [String: (Date, String)] = [:]
    private var heartbeat: Task<Void, Never>?
    private var listener: ClusterListener?
    private var discovery: ClusterDiscovery?

    public init(directory state: URL, executor: @escaping Executor) throws {
        self.directory = state.appendingPathComponent("cluster")
        self.executor = executor
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let keyURL = directory.appendingPathComponent("node-ed25519")
        let key: Curve25519.Signing.PrivateKey
        if FileManager.default.fileExists(atPath: keyURL.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: keyURL.path)
            guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { throw KilnError.message("Cluster private key must have mode 0600") }
            key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: keyURL))
        } else {
            key = Curve25519.Signing.PrivateKey()
            try KilnStateFile.write(key.rawRepresentation, to: keyURL)
        }
        privateKey = NIOSSHPrivateKey(ed25519Key: key)
        let publicKey = String(openSSHPublicKey: privateKey.publicKey)
        identity = ClusterIdentity(fingerprint: try Self.fingerprint(publicKey), publicKey: publicKey)
        let file = directory.appendingPathComponent("peers.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard data.count <= 262144 else { throw KilnError.message("Cluster peer index exceeds size limit") }
            index = try JSONDecoder().decode(Index.self, from: data)
            guard index.peers.count <= 32, index.candidates.count <= 128 else { throw KilnError.message("Cluster peer limits exceeded") }
            for (fingerprint, peer) in Array(index.peers) + Array(index.candidates) {
                guard fingerprint == peer.fingerprint, try Self.fingerprint(peer.publicKey) == fingerprint else { throw KilnError.message("Invalid cluster peer identity") }
                try Self.validateEndpoint(peer.host, peer.port)
            }
        } else { index = Index() }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("outbound"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("receipts"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public static func fingerprint(_ key: String) throws -> String {
        guard key.utf8.count <= 256, key.hasPrefix("ssh-ed25519 ") else { throw KilnError.message("Expected Ed25519 node public key") }
        _ = try NIOSSHPublicKey(openSSHPublicKey: key)
        let fields = key.split(separator: " ")
        guard fields.count == 2, let wire = Data(base64Encoded: String(fields[1])) else { throw KilnError.message("Invalid node key") }
        return "SHA256:" + Data(SHA256.hash(data: wire)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
    static func validateEndpoint(_ host: String, _ port: Int) throws {
        guard (1...65535).contains(port), !host.isEmpty, host.utf8.count <= 253,
              host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:").contains($0) }),
              host != "0.0.0.0", host != "::", host != "255.255.255.255" else { throw KilnError.message("Invalid node endpoint") }
    }
    private func persist(_ value: Index) throws {
        guard !stopping, !persistenceFault else { throw KilnError.message("Cluster persistence requires recovery") }
        var durable = value
        durable.candidates = [:] // Unverified advertisements never become durable trust material.
        do { try KilnStateFile.write(try JSONEncoder().encode(durable), to: directory.appendingPathComponent("peers.json")) }
        catch { if error is KilnStateFile.CommitUncertain { persistenceFault = true }; throw error }
        index = value
    }
    public func candidate(host: String, port: Int, publicKey: String) throws -> ClusterPeer {
        guard !stopping, !persistenceFault else { throw KilnError.message("Cluster state requires recovery; restart before new operations") }
        try Self.validateEndpoint(host, port)
        let fingerprint = try Self.fingerprint(publicKey)
        guard fingerprint != identity.fingerprint else { throw KilnError.message("Cannot discover this node as its own peer") }
        let peer = ClusterPeer(fingerprint: fingerprint, publicKey: publicKey, host: host, port: port, discoveredAt: Date())
        // Advertisements can never rewrite an accepted endpoint or trust a key.
        if let trusted = index.peers[fingerprint] { return trusted }
        var updated = index
        updated.candidates = updated.candidates.filter { Date().timeIntervalSince($0.value.discoveredAt) < 120 }
        if updated.candidates[fingerprint] == nil && updated.candidates.count >= 128 { throw KilnError.message("Candidate list full; clear stale candidates before discovery") }
        updated.candidates[fingerprint] = peer
        index = updated // Discovery is untrusted and ephemeral; never fsync network advertisements.
        return peer
    }
    public func discover(host: String, port: Int) async throws -> ClusterPeer {
        guard !stopping, !persistenceFault, outgoingRequests < 16 else { throw KilnError.message("Cluster unavailable or outbound request limit reached") }
        try Self.validateEndpoint(host, port)
        outgoingRequests += 1
        defer { outgoingRequests -= 1 }
        let key = try await ClusterTransport.scan(host: host, port: port)
        return try candidate(host: host, port: port, publicKey: key)
    }
    public func candidates() -> [ClusterPeer] { index.candidates.values.filter { Date().timeIntervalSince($0.discoveredAt) < 120 }.sorted { $0.fingerprint < $1.fingerprint } }
    public func peers() -> [ClusterPeer] { index.peers.values.sorted { $0.fingerprint < $1.fingerprint } }
    public func accept(_ fingerprint: String) throws -> String {
        guard !stopping, !persistenceFault else { throw KilnError.message("Cluster state requires recovery") }
        guard let candidate = index.candidates[fingerprint], Date().timeIntervalSince(candidate.discoveredAt) < 120 else { throw KilnError.message("Unknown candidate fingerprint; discover and verify it out of band first") }
        guard index.peers.count < 32 else { throw KilnError.message("Peer limit reached") }
        var updated = index; updated.peers[fingerprint] = candidate; updated.candidates.removeValue(forKey: fingerprint)
        try persist(updated)
        return "Accepted \(fingerprint). The other node must explicitly accept this node too."
    }
    public func revoke(_ fingerprint: String) throws -> String {
        guard !stopping, !persistenceFault else { throw KilnError.message("Cluster state requires recovery") }
        var updated = index; updated.peers.removeValue(forKey: fingerprint); updated.candidates.removeValue(forKey: fingerprint)
        try persist(updated); reachability.removeValue(forKey: fingerprint)
        return "Revoked \(fingerprint). New requests, including requests on existing connections, are denied."
    }
    public func clearCandidates() throws -> String { var value = index; value.candidates = [:]; try persist(value); return "Cleared discovery candidates" }
    func authorized(_ publicKey: String) -> String? {
        guard !stopping, !persistenceFault, let fingerprint = try? Self.fingerprint(publicKey), index.peers[fingerprint]?.publicKey == publicKey else { return nil }
        return fingerprint
    }
    public func inventory() -> String {
        "Node \(identity.fingerprint)\n" + peers().map { peer in
            let state = reachability[peer.fingerprint]
            return "\(peer.fingerprint) \(peer.host):\(peer.port) \(state?.1 ?? "unprobed") \(state.map { ISO8601DateFormatter().string(from: $0.0) } ?? "")"
        }.joined(separator: "\n")
    }
    public func operate(peer fingerprint: String, operation: ClusterOperation, module: String? = nil, requestID: String = UUID().uuidString.lowercased()) async throws -> ClusterResponse {
        guard !stopping, !persistenceFault, let peer = index.peers[fingerprint] else { throw KilnError.message("Peer is not adopted") }
        let request = ClusterRequest(id: requestID, operation: operation, module: module)
        try Self.validate(request)
        guard outgoingRequests < 16 else { throw KilnError.message("Cluster outbound request limit reached") }
        if operation != .status {
            guard sendingMutations.insert(requestID).inserted else { throw KilnError.message("Peer request \(requestID) is already in flight; inspect its receipt instead of sending it again") }
        }
        outgoingRequests += 1
        defer { outgoingRequests -= 1; if operation != .status { sendingMutations.remove(requestID) } }
        let path = directory.appendingPathComponent("outbound/" + requestID + ".json")
        var outbound = Outbound(peer: fingerprint, request: request, response: nil)
        if operation != .status {
            if FileManager.default.fileExists(atPath: path.path) {
                outbound = try JSONDecoder().decode(Outbound.self, from: Data(contentsOf: path))
                guard outbound.peer == fingerprint, outbound.request.operation == operation, outbound.request.module == module else { throw KilnError.message("Outbound ID reused with a different peer or operation") }
                if let response = outbound.response { return response }
                throw KilnError.message("Peer request \(requestID) already has an uncertain outcome. Query its receipt; the original mutation will not be retransmitted.")
            } else {
                guard try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("outbound").path).count < 10000 else { throw KilnError.message("Outbound journal full") }
                do { try KilnStateFile.write(try JSONEncoder().encode(outbound), to: path) }
                catch { if error is KilnStateFile.CommitUncertain { persistenceFault = true }; throw error }
            }
        }
        do {
            let response = try await ClusterTransport.execute(peer: peer, key: privateKey, request: request)
            guard !stopping, index.peers[fingerprint]?.publicKey == peer.publicKey, !persistenceFault else { throw KilnError.message("Peer revoked or local persistence uncertain during operation") }
            reachability[fingerprint] = (Date(), "reachable")
            if operation != .status {
                outbound.response = response
                do { try KilnStateFile.write(try JSONEncoder().encode(outbound), to: path) }
                catch { if error is KilnStateFile.CommitUncertain { persistenceFault = true }; throw error }
            }
            return response
        } catch {
            reachability[fingerprint] = (Date(), "unreachable")
            if operation == .status { throw KilnError.message("Peer status unavailable: \(error)") }
            throw KilnError.message("Peer request \(requestID) did not produce a confirmed local outcome: \(error). Query node receipt with this ID; never blindly retry with a new ID.")
        }
    }
    public func operations() throws -> String {
        let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("outbound"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        let summaries = try files.map { path in
            let item = try JSONDecoder().decode(Outbound.self, from: Data(contentsOf: path))
            return (request: item.request, peer: item.peer, state: item.response?.state ?? "unconfirmed")
        }.sorted { left, right in
            let confirmed = ["completed", "failed", "rejected"]
            let leftUncertain = !confirmed.contains(left.state), rightUncertain = !confirmed.contains(right.state)
            if leftUncertain != rightUncertain { return leftUncertain }
            if left.request.issuedAt != right.request.issuedAt { return left.request.issuedAt > right.request.issuedAt }
            return left.request.id < right.request.id
        }
        guard !summaries.isEmpty else { return "No outbound peer operations." }
        let shown = summaries.prefix(100)
        let heading = "Showing \(shown.count) of \(summaries.count) outbound operations (unconfirmed first, newest first)." + (summaries.count > 100 ? " Older records remain in cluster/outbound; inspect them through local administration." : "")
        return heading + "\n" + shown.map { item in
            "\(item.request.id) \(item.peer) \(item.request.operation.rawValue) \(item.request.module ?? "") \(item.state)"
        }.joined(separator: "\n")
    }
    public func receipt(peer fingerprint: String, requestID: String) async throws -> ClusterResponse {
        guard !stopping, !persistenceFault, let peer = index.peers[fingerprint], UUID(uuidString: requestID)?.uuidString.lowercased() == requestID else { throw KilnError.message("Unknown peer or invalid operation ID") }
        guard outgoingRequests < 16 else { throw KilnError.message("Cluster outbound request limit reached") }
        outgoingRequests += 1
        defer { outgoingRequests -= 1 }
        let request = ClusterRequest(operation: .status, receiptID: requestID)
        let response = try await ClusterTransport.execute(peer: peer, key: privateKey, request: request)
        guard !stopping, !persistenceFault, index.peers[fingerprint]?.publicKey == peer.publicKey else { throw KilnError.message("Peer revoked or local state requires recovery during receipt lookup") }
        // A read-only remote lookup can reconcile our local journal, but can
        // never send the original mutation or erase an uncertain outcome.
        // "rejected" describes this lookup request (for example admission
        // overload), not the original mutation whose receipt was requested.
        guard response.state != "rejected" else { throw KilnError.message("Receipt lookup rejected; the outcome of \(requestID) is unchanged: \(response.output)") }
        if ["completed", "failed"].contains(response.state) {
            let path = directory.appendingPathComponent("outbound/" + requestID + ".json")
            if FileManager.default.fileExists(atPath: path.path) {
                var outbound = try JSONDecoder().decode(Outbound.self, from: Data(contentsOf: path))
                if outbound.peer == fingerprint, outbound.request.id == requestID {
                    outbound.response = ClusterResponse(id: requestID, state: response.state, output: response.output)
                    do { try KilnStateFile.write(try JSONEncoder().encode(outbound), to: path) }
                    catch {
                        if error is KilnStateFile.CommitUncertain { persistenceFault = true }
                        throw KilnError.message("Receipt \(requestID) was retrieved as \(response.state), but its local reconciliation could not be recorded. Inspect state; do not replay the mutation.")
                    }
                }
            }
        }
        return response
    }
    public func receive(_ request: ClusterRequest, from peer: String) async throws -> ClusterResponse {
        guard !stopping, !persistenceFault, index.peers[peer] != nil else { throw KilnError.message("Peer is not adopted or was revoked") }
        try Self.validate(request)
        // Work can outlive its SSH connection. Bound actor-dispatched work,
        // not merely the currently open sockets, before any receipt or effect.
        guard incomingRequests < 32 else { throw KilnError.message("Cluster incoming request limit reached; no new operation was started") }
        incomingRequests += 1
        defer { incomingRequests -= 1 }
        if request.operation == .status {
            if let target = request.receiptID {
                let path = directory.appendingPathComponent("receipts/" + target + ".json")
                guard FileManager.default.fileExists(atPath: path.path) else { return ClusterResponse(id: request.id, state: "missing", output: "No receipt for \(target). This lookup does not start an operation.") }
                let record = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: path))
                guard record.peer == peer else { throw KilnError.message("Receipt belongs to another peer") }
                return ClusterResponse(id: request.id, state: record.response.state == "started" ? "unconfirmed" : record.response.state, output: "Operation \(target): \(record.response.output)")
            }
            return ClusterResponse(id: request.id, state: "completed", output: String(try await executor(.status, nil).prefix(24000)))
        }
        let path = directory.appendingPathComponent("receipts/" + request.id + ".json")
        if FileManager.default.fileExists(atPath: path.path) {
            let record = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: path))
            guard record.peer == peer, record.request.operation == request.operation, record.request.module == request.module else { throw KilnError.message("Request ID reused with different actor or operation") }
            if record.response.state == "started" { return ClusterResponse(id: request.id, state: "unconfirmed", output: "Request was already started. Inspect module status; it will not be replayed.") }
            return record.response
        }
        guard abs(request.issuedAt.timeIntervalSinceNow) < 300 else { throw KilnError.message("New peer request expired or clock skew exceeds five minutes") }
        let receiptCount = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("receipts").path).count
        guard receiptCount < 10000 else { throw KilnError.message("Peer operation receipt limit reached; preserve audit records before maintenance") }
        var record = Receipt(peer: peer, request: request, response: ClusterResponse(id: request.id, state: "started", output: ""))
        do { try KilnStateFile.write(try JSONEncoder().encode(record), to: path) }
        catch { if error is KilnStateFile.CommitUncertain { persistenceFault = true }; throw error }
        do { record.response = ClusterResponse(id: request.id, state: "completed", output: String(try await executor(request.operation, request.module).prefix(24000))) }
        catch { record.response = ClusterResponse(id: request.id, state: "failed", output: "Operation failed: \(String(describing: error).prefix(2000))") }
        do { try KilnStateFile.write(try JSONEncoder().encode(record), to: path) }
        catch { if error is KilnStateFile.CommitUncertain { persistenceFault = true }; return ClusterResponse(id: request.id, state: "unconfirmed", output: "Operation returned but its durable outcome could not be recorded. Inspect state; do not replay.") }
        return record.response
    }
    private static func validate(_ request: ClusterRequest) throws {
        guard let uuid = UUID(uuidString: request.id), uuid.uuidString.lowercased() == request.id else { throw KilnError.message("Request ID must be a lowercase UUID") }
        if let target = request.receiptID { guard request.operation == .status, UUID(uuidString: target)?.uuidString.lowercased() == target else { throw KilnError.message("Invalid receipt lookup") } }
        if request.operation == .status { guard request.module == nil else { throw KilnError.message("Status does not accept a module") }; return }
        guard let module = request.module, module.utf8.count <= 128, module.split(separator: "/", omittingEmptySubsequences: false).count == 2,
              module.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./").contains($0) }),
              !module.contains(".."), !module.hasPrefix("/"), !module.hasSuffix("/") else { throw KilnError.message("Expected application/module identifier") }
    }
    public func start(host: String, port: Int, discoveryPort: Int? = nil) async throws {
        guard !starting, shutdownTask == nil, listener == nil else { throw KilnError.message("Cluster listener already started or changing lifecycle") }
        starting = true
        stopping = false
        defer { starting = false }
        let opened = try await ClusterListener.start(host: host, port: port, key: privateKey, cluster: self)
        var advertisements: ClusterDiscovery?
        do {
            guard !stopping else { throw KilnError.message("Cluster stopped during startup") }
            if let discoveryPort { advertisements = try await ClusterDiscovery.start(cluster: self, publicKey: identity.publicKey, peerPort: port, discoveryPort: discoveryPort) }
            guard !stopping else { throw KilnError.message("Cluster stopped during startup") }
        } catch {
            await advertisements?.stop()
            await opened.stop()
            throw error
        }
        listener = opened
        discovery = advertisements
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshPeers()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }
    private func refreshPeers() async {
        // Four concurrent probes max, irrespective of peer count.
        let ids = peers().map(\.fingerprint)
        for start in stride(from: 0, to: ids.count, by: 4) {
            await withTaskGroup(of: Void.self) { group in
                for id in ids[start..<min(start + 4, ids.count)] { group.addTask { _ = try? await self.operate(peer: id, operation: .status) } }
            }
        }
    }
    public func stop() async {
        if let shutdownTask { await shutdownTask.value; return }
        stopping = true
        heartbeat?.cancel(); heartbeat = nil
        let advertisements = discovery, opened = listener
        discovery = nil; listener = nil
        let task = Task<Void, Never> { await advertisements?.stop(); await opened?.stop() }
        shutdownTask = task
        await task.value
        shutdownTask = nil
    }
}
