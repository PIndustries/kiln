import Foundation
import Crypto
import KilnKit
import KilnVault
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Official OSS Sign in with ChatGPT. Tokens are encrypted in KilnVault;
/// metadata binds every registration to its original Kiln principal.
public actor ChatGPTSignIn {
    public struct Start: Sendable { public let id: String; public let authorizationURL: String; public let callbackURI: String }
    public struct AccountSummary: Codable, Sendable {
        public let id: String
        public let owner: String
        public let subject: String
        public let clientID: String
        public let email: String?
        public var signedIn: Bool
        public var planEnabled: Bool
        public var authorizationEpoch: Int? = nil
    }
    public struct Model: Sendable { public let slug: String; public let displayName: String }
    struct Tokens: Codable, Sendable {
        var accessToken: String; var refreshToken: String; var idToken: String; var scopes: [String]; var expiresAt: Date
    }
    struct Pending: Sendable {
        let id: String; let owner: String; let account: AccountSummary?; let state: String; let nonce: String
        let verifier: String; let callbackURI: String; let expires: Date
    }
    struct State: Codable { let hostID: String; var accounts: [AccountSummary] }
    typealias HTTP = @Sendable (URLRequest) async throws -> Data
    private let directory: URL
    private let vault: KilnVault
    private let http: HTTP
    private var state: State
    private var pending: [String: Pending] = [:]
    private var listeners: [String: ChatGPTCallbackListener] = [:]
    private var outcomes: [String: (String, Result<AccountSummary, AIError>)] = [:]
    private var refreshing = Set<String>()
    private var starting = 0
    private var processing: [String: Pending] = [:]
    private var cancelled = Set<String>()
    public init(directory: URL, vault: KilnVault) throws {
        try self.init(directory: directory, vault: vault, http: Self.request)
    }
    init(directory: URL, vault: KilnVault, http: @escaping HTTP) throws {
        self.directory = directory; self.vault = vault; self.http = http
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = try ChatGPTStateLock(directory: directory); defer { lock.release() }
        let url = directory.appendingPathComponent("chatgpt-accounts.json")
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard data.count <= 262144 else { throw AIError.message("ChatGPT account metadata exceeded its limit") }
            state = try JSONDecoder().decode(State.self, from: data)
            guard state.hostID.hasPrefix("urn:uuid:"), UUID(uuidString: String(state.hostID.dropFirst(9))) != nil,
                  state.accounts.count <= 64, Set(state.accounts.map(\.id)).count == state.accounts.count,
                  state.accounts.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.clientID != "dynamic_agent_client" }) else { throw AIError.message("Invalid ChatGPT account metadata") }
        } else {
            state = State(hostID: "urn:uuid:" + UUID().uuidString.lowercased(), accounts: [])
            try KilnStateFile.write(JSONEncoder().encode(state), to: url)
        }
    }
    private func reload() throws {
        let data = try Data(contentsOf: directory.appendingPathComponent("chatgpt-accounts.json"))
        guard data.count <= 262144 else { throw AIError.message("ChatGPT account metadata exceeded its limit") }
        let updated = try JSONDecoder().decode(State.self, from: data)
        guard updated.hostID == state.hostID, updated.accounts.count <= 64,
              Set(updated.accounts.map(\.id)).count == updated.accounts.count,
              updated.accounts.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.clientID != "dynamic_agent_client" }) else {
            throw AIError.message("ChatGPT account metadata changed unexpectedly")
        }
        state = updated
    }
    private func persist() throws { try KilnStateFile.write(JSONEncoder().encode(state), to: directory.appendingPathComponent("chatgpt-accounts.json")) }
    private func account(_ id: String, owner: String) throws -> AccountSummary {
        guard let found = state.accounts.first(where: { $0.id == id && $0.owner == owner }) else { throw AIError.message("ChatGPT account unavailable for this identity") }
        return found
    }
    private func tokens(_ id: String) throws -> Tokens {
        guard let value = try vault.environment(for: "kiln/chatgpt-" + id, bindings: ["TOKEN": "chatgpt-" + id])["TOKEN"],
              let data = value.data(using: .utf8), data.count <= 16384 else { throw AIError.message("ChatGPT credentials unavailable; sign in again") }
        return try JSONDecoder().decode(Tokens.self, from: data)
    }
    private func save(_ tokens: Tokens, id: String) throws {
        let data = try JSONEncoder().encode(tokens)
        guard data.count <= 16384 else { throw AIError.message("ChatGPT credential record exceeded Vault limit") }
        _ = try vault.put("chatgpt-" + id, value: String(decoding: data, as: UTF8.self))
        _ = try vault.grant("chatgpt-" + id, to: "kiln/chatgpt-" + id)
    }
    public func accounts(owner: String) -> [AccountSummary] { state.accounts.filter { $0.owner == owner } }
    /// Inspect saved local state without token renewal, remote discovery or inference.
    public func localCredentialStatus(account id: String, owner: String) throws -> String {
        let lock = try ChatGPTStateLock(directory: directory); defer { lock.release() }
        try reload()
        let account = try self.account(id, owner: owner)
        guard account.signedIn, account.planEnabled else { throw AIError.message("ChatGPT sign-in or plan permission unavailable") }
        let saved = try tokens(id)
        guard !saved.accessToken.isEmpty, !saved.refreshToken.isEmpty, !saved.idToken.isEmpty,
              saved.scopes.contains("chatgpt.tokens.use.direct") else { throw AIError.message("Saved ChatGPT grant unavailable") }
        return saved.expiresAt > Date().addingTimeInterval(60)
            ? "Saved sign-in and encrypted grant available for this identity."
            : "Saved grant available; renewal will be required on the next request."
    }
    public func start(owner: String, account id: String? = nil, port: Int = 0) async throws -> Start {
        guard !owner.isEmpty, owner.utf8.count <= 512, (0...65535).contains(port), pending.count + processing.count + starting < 8,
              id != nil || state.accounts.count < 64 else { throw AIError.message("ChatGPT sign-in capacity or parameters invalid") }
        starting += 1
        defer { starting -= 1 }
        let selected = try id.map { try account($0, owner: owner) }
        let attemptID = UUID().uuidString.lowercased()
        let listener = try await ChatGPTCallbackListener.start(port: port) { [weak self] target in
            await self?.callback(id: attemptID, target: target)
        }
        let callbackURI = "http://127.0.0.1:\(listener.port)/auth/callback"
        let attempt = Pending(id: attemptID, owner: owner, account: selected, state: ChatGPTIdentity.random(), nonce: ChatGPTIdentity.random(), verifier: ChatGPTIdentity.random(), callbackURI: callbackURI, expires: Date().addingTimeInterval(600))
        pending[attemptID] = attempt; listeners[attemptID] = listener
        var query = ["client_id": selected?.clientID ?? "dynamic_agent_client", "ext_agent_host_id": state.hostID,
                     "response_type": "code", "redirect_uri": callbackURI,
                     "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
                     "resource": "https://api.openai.com/v1", "state": attempt.state, "nonce": attempt.nonce,
                     "code_challenge_method": "S256", "code_challenge": ChatGPTIdentity.base64url(Data(SHA256.hash(data: Data(attempt.verifier.utf8))))]
        if selected == nil { query["agent_name_hint"] = "Kiln" }
        // Do not put ID-token hints into the URL shown by SSH/CLI: the normal
        // account selector is sufficient and avoids exposing tokens in history.
        var url = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            await self?.expire(attemptID)
        }
        return Start(id: attemptID, authorizationURL: url.url!.absoluteString, callbackURI: callbackURI)
    }
    public func result(id: String, owner: String) throws -> AccountSummary? {
        if let outcome = outcomes[id], outcome.0 == owner { return try outcome.1.get() }
        if processing[id]?.owner == owner { return nil }
        if let attempt = pending[id] {
            guard attempt.owner == owner else { throw AIError.message("Sign-in attempt unavailable") }
            return nil
        }
        guard let outcome = outcomes[id], outcome.0 == owner else { throw AIError.message("Sign-in attempt unavailable") }
        return try outcome.1.get()
    }
    public func cancel(id: String, owner: String) async throws {
        guard let attempt = pending[id] ?? processing[id], attempt.owner == owner else { throw AIError.message("Sign-in attempt unavailable") }
        pending.removeValue(forKey: id)
        if processing[id] != nil { cancelled.insert(id) }
        finish(id, owner: owner, result: .failure(.message("ChatGPT sign-in cancelled")))
        await listeners.removeValue(forKey: id)?.close()
    }
    private func expire(_ id: String) async {
        guard let attempt = pending[id] else { return }
        pending.removeValue(forKey: id)
        finish(id, owner: attempt.owner, result: .failure(.message("ChatGPT sign-in expired; start again")))
        await listeners.removeValue(forKey: id)?.close()
    }
    private func finish(_ id: String, owner: String, result: Result<AccountSummary, AIError>) {
        if outcomes.count >= 64, let first = outcomes.keys.first { outcomes.removeValue(forKey: first) }
        outcomes[id] = (owner, result)
    }
    func callback(id: String, target: String) async {
        guard let attempt = pending[id] else { return }
        // Reject unsolicited callbacks without consuming a legitimate attempt.
        guard let components = URLComponents(string: attempt.callbackURI + String(target.dropFirst("/auth/callback".count))),
              target.hasPrefix("/auth/callback?"), let items = components.queryItems,
              items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == attempt.state else { return }
        pending.removeValue(forKey: id) // One-time consumption before any network work.
        processing[id] = attempt
        defer { processing.removeValue(forKey: id); cancelled.remove(id) }
        do {
            let lock = try ChatGPTStateLock(directory: directory); defer { lock.release() }
            try reload()
            let exchange = try Self.exchangeRequest(attempt: attempt, items: items)
            let data = try await http(exchange.request)
            let jwks = try await http(URLRequest(url: URL(string: "https://auth.openai.com/.well-known/jwks.json")!))
            let token = try Self.decodeTokens(data)
            let identity = try ChatGPTIdentity.validate(token.idToken, jwks: jwks, clientID: exchange.clientID, nonce: attempt.nonce, subject: attempt.account?.subject)
            guard !cancelled.contains(id) else { throw AIError.message("ChatGPT sign-in cancelled") }
            if let selected = attempt.account {
                let latest = try self.account(selected.id, owner: attempt.owner)
                guard (latest.authorizationEpoch ?? 0) == (selected.authorizationEpoch ?? 0) else {
                    throw AIError.message("ChatGPT authorization was invalidated by sign-out")
                }
            } else {
                guard state.accounts.count < 64 else { throw AIError.message("ChatGPT account limit reached") }
            }
            let accountID = attempt.account?.id ?? UUID().uuidString.lowercased()
            guard !state.accounts.contains(where: { $0.clientID == exchange.clientID && $0.id != accountID }) else { throw AIError.message("ChatGPT registration already belongs to another saved account") }
            let account = AccountSummary(id: accountID, owner: attempt.owner, subject: identity.subject, clientID: exchange.clientID, email: identity.email, signedIn: true, planEnabled: token.scopes.contains("chatgpt.tokens.use.direct"), authorizationEpoch: attempt.account?.authorizationEpoch)
            try save(token, id: accountID)
            let previousState = state
            state.accounts.removeAll { $0.id == accountID }; state.accounts.append(account)
            do { try persist() } catch { state = previousState; throw error }
            finish(id, owner: attempt.owner, result: .success(account))
        } catch {
            finish(id, owner: attempt.owner, result: .failure(.message("ChatGPT sign-in could not be validated or saved; start again. No account was activated.")))
        }
        await listeners.removeValue(forKey: id)?.close()
    }
    static func exchangeRequest(attempt: Pending, items: [URLQueryItem], now: Date = Date()) throws -> (request: URLRequest, clientID: String) {
        guard attempt.expires > now, items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == attempt.state,
              items.allSatisfy({ item in items.filter { $0.name == item.name }.count == 1 }),
              !items.contains(where: { $0.name == "error" }),
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty, code.utf8.count <= 8192 else { throw AIError.message("Invalid or denied ChatGPT authorization callback") }
        let callbackClient = items.first(where: { $0.name == "client_id" })?.value
        guard let client = callbackClient ?? attempt.account?.clientID, !client.isEmpty, client != "dynamic_agent_client", client.utf8.count <= 256,
              attempt.account == nil || client == attempt.account?.clientID else { throw AIError.message("ChatGPT registration identity changed") }
        return (formRequest(endpoint: "https://auth.openai.com/api/accounts/oauth/token", values: ["grant_type": "authorization_code", "client_id": client, "code": code, "code_verifier": attempt.verifier, "redirect_uri": attempt.callbackURI, "resource": "https://api.openai.com/v1"]), client)
    }
    static func formRequest(endpoint: String, values: [String: String]) -> URLRequest {
        var encoded = URLComponents(); encoded.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((encoded.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        return request
    }
    static func decodeTokens(_ data: Data, previous: Tokens? = nil) throws -> Tokens {
        guard data.count <= 65536, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String, !access.isEmpty,
              let refresh = object["refresh_token"] as? String ?? previous?.refreshToken, !refresh.isEmpty,
              let identity = object["id_token"] as? String ?? previous?.idToken, !identity.isEmpty,
              (object["token_type"] as? String)?.lowercased() == "bearer",
              let seconds = object["expires_in"] as? Double, seconds > 0, seconds <= 604800,
              let scope = object["scope"] as? String ?? previous.map({ $0.scopes.joined(separator: " ") }) else { throw AIError.message("Invalid ChatGPT credential response") }
        let tokens = Tokens(accessToken: access, refreshToken: refresh, idToken: identity, scopes: scope.split(separator: " ").map(String.init), expiresAt: Date().addingTimeInterval(seconds))
        guard try JSONEncoder().encode(tokens).count <= 16384 else { throw AIError.message("ChatGPT credentials exceeded Vault record limit") }
        return tokens
    }
    public func accessToken(account id: String, owner: String, forceRefresh: Bool = false) async throws -> String {
        let account = try account(id, owner: owner)
        guard account.signedIn, account.planEnabled else { throw AIError.message("Continue with ChatGPT and enable ChatGPT plan usage first") }
        guard refreshing.insert(id).inserted else { throw AIError.message("ChatGPT account refresh is already in progress; try again") }
        defer { refreshing.remove(id) }
        let lock = try ChatGPTStateLock(directory: directory); defer { lock.release() }
        try reload()
        let current = try self.account(id, owner: owner)
        guard current.signedIn, current.planEnabled else { throw AIError.message("ChatGPT account was signed out") }
        let old = try tokens(id)
        guard old.scopes.contains("chatgpt.tokens.use.direct") else { throw AIError.message("ChatGPT plan usage is not authorized") }
        if !forceRefresh, old.expiresAt.timeIntervalSinceNow > 60 { return old.accessToken }
        let request = Self.formRequest(endpoint: "https://auth.openai.com/api/accounts/oauth/token", values: ["grant_type": "refresh_token", "client_id": account.clientID, "refresh_token": old.refreshToken, "resource": "https://api.openai.com/v1"])
        let data = try await http(request)
        let renewed = try Self.decodeTokens(data, previous: old)
        if renewed.idToken != old.idToken {
            let jwks = try await http(URLRequest(url: URL(string: "https://auth.openai.com/.well-known/jwks.json")!))
            _ = try ChatGPTIdentity.validate(renewed.idToken, jwks: jwks, clientID: account.clientID, nonce: nil, subject: account.subject)
        }
        try save(renewed, id: id)
        guard renewed.scopes.contains("chatgpt.tokens.use.direct") else { throw AIError.message("ChatGPT plan usage is no longer authorized") }
        return renewed.accessToken
    }
    public func signOut(account id: String, owner: String) async throws -> Bool {
        let account = try account(id, owner: owner)
        // Logout invalidates outstanding reauthorization before awaiting network
        // revocation. A late callback cannot silently sign this account back in.
        let attempts = Array(pending.values) + Array(processing.values)
        for attempt in attempts where attempt.owner == owner && attempt.account?.id == id {
            pending.removeValue(forKey: attempt.id)
            if processing[attempt.id] != nil { cancelled.insert(attempt.id) }
            finish(attempt.id, owner: owner, result: .failure(.message("ChatGPT sign-in cancelled by sign-out")))
            if let listener = listeners.removeValue(forKey: attempt.id) { Task { await listener.close() } }
        }
        guard refreshing.insert(id).inserted else { throw AIError.message("ChatGPT account is busy; try again") }
        defer { refreshing.remove(id) }
        let lock = try ChatGPTStateLock(directory: directory); defer { lock.release() }
        try reload()
        var confirmed = false
        if let tokens = try? tokens(id) {
            do {
                let discovery = try await http(URLRequest(url: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!))
                guard let object = try JSONSerialization.jsonObject(with: discovery) as? [String: Any], object["issuer"] as? String == "https://auth.openai.com",
                      let endpoint = object["revocation_endpoint"] as? String, let url = URL(string: endpoint), url.scheme == "https", url.host == "auth.openai.com", url.user == nil, url.password == nil, url.port == nil else { throw AIError.message("Invalid ChatGPT revocation discovery") }
                _ = try await http(Self.formRequest(endpoint: endpoint, values: ["token": tokens.refreshToken, "token_type_hint": "refresh_token", "client_id": account.clientID]))
                confirmed = true
            } catch { /* Clear locally even if the remote service is unavailable. */ }
        }
        _ = try vault.revoke("chatgpt-" + id, from: "kiln/chatgpt-" + id)
        _ = try vault.delete("chatgpt-" + id)
        if let index = state.accounts.firstIndex(where: { $0.id == id }) {
            state.accounts[index].signedIn = false; state.accounts[index].planEnabled = false
            state.accounts[index].authorizationEpoch = (state.accounts[index].authorizationEpoch ?? 0) + 1
        }
        try persist()
        return confirmed
    }
    public func models(account id: String, owner: String) async throws -> [Model] {
        let token = try await accessToken(account: id, owner: owner)
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let data = try await http(request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let models = object["models"] as? [[String: Any]], models.count <= 1024 else { throw AIError.message("Invalid ChatGPT model catalog") }
        return models.compactMap { entry in
            guard entry["visibility"] as? String == "list", let slug = entry["slug"] as? String, let name = entry["display_name"] as? String, slug.utf8.count <= 256, name.utf8.count <= 256 else { return nil }
            return Model(slug: slug, displayName: name)
        }
    }
    private static func request(_ request: URLRequest) async throws -> Data {
        let options = URLSessionConfiguration.ephemeral
        options.httpCookieStorage = nil; options.urlCache = nil; options.timeoutIntervalForRequest = 30; options.timeoutIntervalForResource = 60
        do { return try await BoundedCompletionHTTP.data(for: request, configuration: options) }
        catch { if Task.isCancelled { throw CancellationError() }; throw AIError.message("ChatGPT authorization request failed; sign in again or retry later") }
    }
}

private final class ChatGPTStateLock {
    private var descriptor: Int32
    init(directory: URL) throws {
        descriptor = open(directory.appendingPathComponent("chatgpt.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AIError.message("Cannot lock ChatGPT accounts") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); descriptor = -1; throw AIError.message("ChatGPT account storage is busy; try again") }
    }
    func release() { if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 } }
    deinit { release() }
}
