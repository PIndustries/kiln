import Foundation
import Crypto
import _CryptoExtras

/// Strict RS256 identity verification; decoded claims alone are never identity.
enum ChatGPTIdentity {
    struct Claims: Sendable { let subject: String; let email: String? }
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ string: String) throws -> Data {
        guard !string.isEmpty, string.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let data = Data(base64Encoded: string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - string.count % 4) % 4)) else {
            throw AIError.message("Invalid ChatGPT identity encoding")
        }
        return data
    }
    static func random() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64url(Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }))
    }
    static func validate(_ jwt: String, jwks: Data, clientID: String, nonce: String?, subject: String? = nil, now: Date = Date()) throws -> Claims {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard jwt.utf8.count <= 16384, parts.count == 3,
              let header = try JSONSerialization.jsonObject(with: decode(parts[0])) as? [String: Any],
              header["alg"] as? String == "RS256", header["crit"] == nil,
              let kid = header["kid"] as? String, !kid.isEmpty,
              let set = try JSONSerialization.jsonObject(with: jwks) as? [String: Any],
              let keys = set["keys"] as? [[String: Any]] else { throw AIError.message("Invalid ChatGPT identity signature metadata") }
        let matching = keys.filter { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }
        guard matching.count == 1, let key = matching.first,
              key["alg"] == nil || key["alg"] as? String == "RS256",
              key["use"] == nil || key["use"] as? String == "sig",
              let n = key["n"] as? String, let e = key["e"] as? String else { throw AIError.message("Unknown ChatGPT identity signing key") }
        let publicKey = try _RSA.Signing.PublicKey(n: decode(n), e: decode(e))
        let signed = Data((parts[0] + "." + parts[1]).utf8)
        guard publicKey.isValidSignature(.init(rawRepresentation: try decode(parts[2])), for: signed, padding: .insecurePKCS1v1_5),
              let claims = try JSONSerialization.jsonObject(with: decode(parts[1])) as? [String: Any],
              claims["iss"] as? String == "https://auth.openai.com",
              let sub = claims["sub"] as? String, !sub.isEmpty, sub.utf8.count <= 512,
              let expiry = claims["exp"] as? Double, expiry > now.timeIntervalSince1970,
              (claims["nbf"] as? Double ?? 0) <= now.timeIntervalSince1970 + 30,
              (claims["iat"] as? Double ?? 0) <= now.timeIntervalSince1970 + 30 else { throw AIError.message("ChatGPT identity signature or claims rejected") }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(clientID),
              claims["azp"] == nil || claims["azp"] as? String == clientID,
              audiences.count == 1 || claims["azp"] as? String == clientID,
              nonce == nil || claims["nonce"] as? String == nonce,
              subject == nil || sub == subject else { throw AIError.message("ChatGPT identity does not match this authorization") }
        let email = claims["email"] as? String
        return Claims(subject: sub, email: email.flatMap { $0.utf8.count <= 320 ? $0 : nil })
    }
}
