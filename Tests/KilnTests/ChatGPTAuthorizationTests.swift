import Foundation
import Testing
import Crypto
import _CryptoExtras
import KilnVault
@testable import KilnAI

@Test func chatGPTIdentityRejectsMismatchedAuthorizedPartyForSingleAudience() throws {
    let key = try _RSA.Signing.PrivateKey(keySize: .bits2048)
    let values = try key.publicKey.getKeyPrimitives()
    let jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "RSA", "kid": "azp-fixture", "n": ChatGPTIdentity.base64url(values.modulus), "e": ChatGPTIdentity.base64url(values.publicExponent)]]])
    let header = ChatGPTIdentity.base64url(try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "azp-fixture"]))
    let claims: [String: Any] = ["iss": "https://auth.openai.com", "sub": "fixture", "aud": "expected-client", "azp": "another-client", "nonce": "expected-nonce", "exp": Date().addingTimeInterval(600).timeIntervalSince1970]
    let payload = ChatGPTIdentity.base64url(try JSONSerialization.data(withJSONObject: claims))
    let input = header + "." + payload
    let signature = try key.signature(for: Data(input.utf8), padding: .insecurePKCS1v1_5)
    let token = input + "." + ChatGPTIdentity.base64url(signature.rawRepresentation)
    #expect(throws: (any Error).self) {
        try ChatGPTIdentity.validate(token, jwks: jwks, clientID: "expected-client", nonce: "expected-nonce")
    }
}

@Test func chatGPTUnsolicitedCallbackDoesNotConsumeAttemptOrContactProvider() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-auth-boundary-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = KilnVault(directory: root.appendingPathComponent("vault"))
    let manager = try ChatGPTSignIn(directory: root, vault: vault, http: { _ in
        Issue.record("Invalid-state callback must not contact provider")
        throw AIError.message("Unexpected provider request")
    })
    let attempt = try await manager.start(owner: "owner-key-fingerprint")
    await manager.callback(id: attempt.id, target: "/auth/callback?state=unsolicited&code=never-exchange&client_id=other")
    #expect(try await manager.result(id: attempt.id, owner: "owner-key-fingerprint") == nil)
    await #expect(throws: (any Error).self) {
        try await manager.result(id: attempt.id, owner: "different-owner")
    }
    try await manager.cancel(id: attempt.id, owner: "owner-key-fingerprint")
}
