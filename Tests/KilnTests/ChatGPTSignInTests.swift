import Foundation
import Testing
import Crypto
import _CryptoExtras
import KilnVault
@testable import KilnAI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct IdentityFixture: Sendable {
    let key: _RSA.Signing.PrivateKey
    let jwks: Data
    init() throws {
        key = try .init(keySize: .bits2048)
        let values = try key.publicKey.getKeyPrimitives()
        jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "RSA", "kid": "fixture", "alg": "RS256", "use": "sig", "n": ChatGPTIdentity.base64url(values.modulus), "e": ChatGPTIdentity.base64url(values.publicExponent)]]])
    }
    func token(client: String = "oaiapp_fixture", nonce: String = "nonce", subject: String = "subject", expiry: Double = Date().addingTimeInterval(3600).timeIntervalSince1970) throws -> String {
        let header = ChatGPTIdentity.base64url(try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "fixture"]))
        let payload = ChatGPTIdentity.base64url(try JSONSerialization.data(withJSONObject: ["iss": "https://auth.openai.com", "aud": client, "sub": subject, "exp": expiry, "nonce": nonce, "email": "fixture@example.invalid"]))
        let signed = header + "." + payload
        let signature = try key.signature(for: Data(signed.utf8), padding: .insecurePKCS1v1_5)
        return signed + "." + ChatGPTIdentity.base64url(signature.rawRepresentation)
    }
}
@Test func chatGPTIdentityChecksSignatureAudienceNonceAndExpiry() throws {
    let fixture = try IdentityFixture()
    let token = try fixture.token()
    #expect(try ChatGPTIdentity.validate(token, jwks: fixture.jwks, clientID: "oaiapp_fixture", nonce: "nonce").subject == "subject")
    for (client, nonce, subject) in [("wrong", "nonce", "subject"), ("oaiapp_fixture", "wrong", "subject"), ("oaiapp_fixture", "nonce", "wrong")] {
        #expect(throws: (any Error).self) { try ChatGPTIdentity.validate(token, jwks: fixture.jwks, clientID: client, nonce: nonce, subject: subject) }
    }
    #expect(throws: (any Error).self) { try ChatGPTIdentity.validate(fixture.token(expiry: 1), jwks: fixture.jwks, clientID: "oaiapp_fixture", nonce: "nonce") }
    let otherKey = try IdentityFixture()
    #expect(throws: (any Error).self) { try ChatGPTIdentity.validate(token, jwks: otherKey.jwks, clientID: "oaiapp_fixture", nonce: "nonce") }
}
@Test func chatGPTExchangeRequiresIssuedClientExactStateAndNoDuplicateParameters() throws {
    let pending = ChatGPTSignIn.Pending(id: "attempt", owner: "owner", account: nil, state: "state", nonce: "nonce", verifier: "verifier", callbackURI: "http://127.0.0.1:1234/auth/callback", expires: Date().addingTimeInterval(60))
    let query = [URLQueryItem(name: "state", value: "state"), URLQueryItem(name: "code", value: "code+fixture"), URLQueryItem(name: "client_id", value: "oaiapp_fixture")]
    let exchange = try ChatGPTSignIn.exchangeRequest(attempt: pending, items: query)
    #expect(exchange.clientID == "oaiapp_fixture")
    let body = try #require(exchange.request.httpBody)
    #expect(String(decoding: body, as: UTF8.self).contains("code%2Bfixture"))
    #expect(!String(decoding: body, as: UTF8.self).contains("client_secret"))
    #expect(throws: (any Error).self) { try ChatGPTSignIn.exchangeRequest(attempt: pending, items: Array(query.prefix(2))) }
    #expect(throws: (any Error).self) { try ChatGPTSignIn.exchangeRequest(attempt: pending, items: query + [query[0]]) }
    #expect(throws: (any Error).self) { try ChatGPTSignIn.exchangeRequest(attempt: pending, items: query, now: Date().addingTimeInterval(120)) }
}
private actor AuthFixtureTransport {
    let identity: IdentityFixture
    var nonce = ""
    var calls = 0
    init(identity: IdentityFixture) { self.identity = identity }
    func setNonce(_ value: String) { nonce = value }
    func request(_ request: URLRequest) throws -> Data {
        if request.url?.path == "/.well-known/jwks.json" { return identity.jwks }
        if request.url?.path == "/.well-known/openid-configuration" { return Data("{\"issuer\":\"https://auth.openai.com\",\"revocation_endpoint\":\"https://auth.openai.com/api/accounts/oauth/revoke\"}".utf8) }
        if request.url?.path == "/api/accounts/oauth/revoke" { return Data() }
        calls += 1
        return try JSONSerialization.data(withJSONObject: ["access_token": "fixture-access-token-\(calls)", "refresh_token": "fixture-refresh-token-\(calls)", "id_token": identity.token(nonce: nonce), "scope": "openid chatgpt.tokens.use.direct resource.invoke offline_access", "token_type": "Bearer", "expires_in": 3600])
    }
}
@Test func chatGPTLoopbackFlowEncryptsCredentialsAndBindsOwner() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-siwc-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = KilnVault(directory: root.appendingPathComponent("vault"))
    _ = try vault.initialize(keyFile: root.appendingPathComponent("key"))
    let transport = AuthFixtureTransport(identity: try IdentityFixture())
    let manager = try ChatGPTSignIn(directory: root, vault: vault, http: { try await transport.request($0) })
    let start = try await manager.start(owner: "alice")
    let url = try #require(URLComponents(string: start.authorizationURL))
    let query = try #require(url.queryItems)
    let nonce = try #require(query.first(where: { $0.name == "nonce" })?.value)
    await transport.setNonce(nonce)
    #expect(query.first(where: { $0.name == "agent_name_hint" })?.value == "Kiln")
    #expect(query.first(where: { $0.name == "client_id" })?.value == "dynamic_agent_client")
    let state = try #require(query.first(where: { $0.name == "state" })?.value)
    let callback = try #require(URL(string: start.callbackURI + "?state=" + state + "&code=fixture&client_id=oaiapp_fixture"))
    _ = try await URLSession.shared.data(from: callback)
    var accepted: ChatGPTSignIn.AccountSummary?
    for _ in 0..<200 {
        accepted = try await manager.result(id: start.id, owner: "alice")
        if accepted != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let account = try #require(accepted)
    #expect(account.signedIn && account.planEnabled)
    #expect(try await manager.accessToken(account: account.id, owner: "alice") == "fixture-access-token-1")
    await #expect(throws: (any Error).self) { try await manager.accessToken(account: account.id, owner: "bob") }
    #expect(await manager.accounts(owner: "bob").isEmpty)
    let metadata = try Data(contentsOf: root.appendingPathComponent("chatgpt-accounts.json"))
    let encrypted = try Data(contentsOf: root.appendingPathComponent("vault/vault.enc"))
    #expect(!String(decoding: metadata + encrypted, as: UTF8.self).contains("fixture-access-token"))
    await manager.callback(id: start.id, target: "/auth/callback?state=" + state + "&code=fixture&client_id=oaiapp_fixture")
    #expect(await transport.calls == 1)
    // Force near expiry in the encrypted fixture and prove rotating credentials
    // are saved as a bundle before the refreshed access token is returned.
    let binding = ["TOKEN": "chatgpt-" + account.id]
    let scope = "kiln/chatgpt-" + account.id
    let saved = try #require(vault.environment(for: scope, bindings: binding)["TOKEN"])
    var expired = try JSONDecoder().decode(ChatGPTSignIn.Tokens.self, from: Data(saved.utf8))
    expired.expiresAt = Date(timeIntervalSince1970: 1)
    _ = try vault.put("chatgpt-" + account.id, value: String(decoding: JSONEncoder().encode(expired), as: UTF8.self))
    #expect(try await manager.accessToken(account: account.id, owner: "alice") == "fixture-access-token-2")
    let rotated = try #require(vault.environment(for: scope, bindings: binding)["TOKEN"])
    #expect(try JSONDecoder().decode(ChatGPTSignIn.Tokens.self, from: Data(rotated.utf8)).refreshToken == "fixture-refresh-token-2")
    #expect(await transport.calls == 2)
    let pendingReauth = try await manager.start(owner: "alice", account: account.id)
    let otherInstance = try ChatGPTSignIn(directory: root, vault: vault, http: { try await transport.request($0) })
    let staleReauth = try await otherInstance.start(owner: "alice", account: account.id)
    #expect(try await manager.signOut(account: account.id, owner: "alice"))
    await #expect(throws: (any Error).self) { try await manager.result(id: pendingReauth.id, owner: "alice") }
    let reauthState = URLComponents(string: pendingReauth.authorizationURL)?.queryItems?.first(where: { $0.name == "state" })?.value ?? ""
    await manager.callback(id: pendingReauth.id, target: "/auth/callback?state=" + reauthState + "&code=fixture&client_id=oaiapp_fixture")
    #expect(await transport.calls == 2)
    // Another process may have started reauthorization before logout. Its
    // valid token response still cannot restore a superseded authorization.
    let staleQuery = URLComponents(string: staleReauth.authorizationURL)?.queryItems ?? []
    let staleState = try #require(staleQuery.first(where: { $0.name == "state" })?.value)
    let staleNonce = try #require(staleQuery.first(where: { $0.name == "nonce" })?.value)
    await transport.setNonce(staleNonce)
    await otherInstance.callback(id: staleReauth.id, target: "/auth/callback?state=" + staleState + "&code=fixture&client_id=oaiapp_fixture")
    await #expect(throws: (any Error).self) { try await otherInstance.result(id: staleReauth.id, owner: "alice") }
    #expect(await transport.calls == 3)
    #expect(await otherInstance.accounts(owner: "alice").first?.signedIn == false)
    await #expect(throws: (any Error).self) { try await manager.accessToken(account: account.id, owner: "alice") }
    let restarted = try ChatGPTSignIn(directory: root, vault: vault, http: { try await transport.request($0) })
    let reauth = try await restarted.start(owner: "alice", account: account.id)
    #expect(URLComponents(string: reauth.authorizationURL)?.queryItems?.first(where: { $0.name == "client_id" })?.value == "oaiapp_fixture")
    try await restarted.cancel(id: reauth.id, owner: "alice")
}
@Test func chatGPTResponsesUsesSubscriptionRequestContract() throws {
    let configuration = AIConfiguration(baseURL: "https://api.openai.com/v1", model: "fixture", secret: UUID().uuidString, provider: .chatgpt)
    let request = try OpenAIResponsesClient.makeRequest(configuration: configuration, key: "fixture", messages: [AIMessage(role: "system", content: "Kiln instructions")], tools: [AITool("system_status", "Inspect")])
    let data = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(body["max_output_tokens"] == nil)
    #expect(body["store"] as? Bool == false)
    #expect((body["input"] as? [[String: Any]])?.first?["role"] as? String == "developer")
    #expect((body["tools"] as? [[String: Any]])?.first?["type"] as? String == "namespace")
}
