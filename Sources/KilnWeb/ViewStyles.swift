import Foundation
import Crypto

/// Stateless, authenticated stylesheet URLs for native modifiers. A linked CSS
/// resource works with style-src 'self', including fragments added by live views;
/// there is no inline-style exception, mutable registry or app JavaScript.
enum ViewStyles {
    private static let key = SymmetricKey(size:.bits256)
    private static func name(_ data: Data) -> String { "kiln-style-"+SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
    static func resource(_ style: String) -> (name: String, path: String) {
        let data = Data(style.utf8)
        precondition(data.count <= 4096,"Native modifier CSS is limited to 4 KiB; use the application stylesheet for larger rules")
        let payload = data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        let signature = HMAC<SHA256>.authenticationCode(for:data,using:key).map{String(format:"%02x",$0)}.joined()
        return (name(data),"/__kiln/style/"+payload+"/"+signature+".css")
    }
    static func stylesheet(_ path: String) -> String? {
        let parts = path.split(separator:"/",omittingEmptySubsequences:true)
        guard parts.count == 4, parts[0] == "__kiln", parts[1] == "style", parts[2].utf8.count <= 5464,
              parts[3].hasSuffix(".css") else { return nil }
        let signature = String(parts[3].dropLast(4))
        guard signature.utf8.count == 64, signature.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        let payload = String(parts[2]).replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")
        guard let data = Data(base64Encoded:payload+String(repeating:"=",count:(4-payload.count%4)%4)), data.count <= 4096,
              let style = String(data:data,encoding:.utf8) else { return nil }
        var mac = Data()
        for offset in stride(from:0,to:signature.count,by:2) {
            let start = signature.index(signature.startIndex,offsetBy:offset), end = signature.index(start,offsetBy:2)
            guard let byte = UInt8(signature[start..<end],radix:16) else { return nil }; mac.append(byte)
        }
        guard HMAC<SHA256>.isValidAuthenticationCode(mac,authenticating:data,using:key) else { return nil }
        return "."+name(data)+"{"+style+"}"
    }
}
