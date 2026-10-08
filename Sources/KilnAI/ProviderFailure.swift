import Foundation
import KilnKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Only fixed, reviewed explanations reach the terminal. Provider messages can
/// contain secrets, internal URLs or terminal escapes and are never displayed.
struct ProviderFailure: Error, CustomStringConvertible {
    var description: String { explanation() }
    var retrySeconds: Int? {
        guard response.statusCode == 429,
              let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let code = error["code"] as? String,
              ["capacity_exceeded", "rate_limit_exceeded"].contains(code),
              let delay = Self.retryDelay(response.value(forHTTPHeaderField: "Retry-After"), now: Date()),
              delay <= 60 else { return nil }
        return delay
    }
    static let maximumBytes = 16_384
    let response: HTTPURLResponse
    private(set) var bytes = Data()
    mutating func append(_ data: Data) -> Bool {
        guard data.count <= Self.maximumBytes - bytes.count else { bytes.removeAll(); return false }
        bytes.append(data); return true
    }
    func explanation(now: Date = Date()) -> String {
        let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        let envelope = object?["error"] as? [String: Any]
        let code = envelope?["code"] as? String
        let status = response.statusCode
        let detail: String
        switch (status, code) {
        case (429, "capacity_exceeded"):
            detail = "Backend capacity is full; wait before trying again."
        case (429, "rate_limit_exceeded"):
            detail = "Request rate limit reached; reduce concurrency and wait before trying again."
        case (429, "quota_exceeded"), (402, "insufficient_quota"), (402, "billing_delinquent"):
            detail = "Account or endpoint quota/billing limit reached; check the Erebine dashboard before retrying."
        case (429, _):
            detail = "The provider limited this request; check capacity, rate limits and quota in Erebine."
        case (401, _): detail = "Authentication was rejected; check the configured Vault credential."
        case (403, _): detail = "Access was denied; check the API key's endpoint permissions."
        case (404, _): detail = "Endpoint or model was not found; check the AI configuration."
        case (503, _): detail = "The provider backend is unavailable; check Erebine status before retrying."
        default: detail = "The provider rejected this request; check endpoint, model and provider status."
        }
        let header = response.value(forHTTPHeaderField: "Retry-After")
        let delay = Self.retryDelay(header, now: now)
        let wait = delay.map { " Retry-After: \($0) seconds." } ?? ""
        return "Erebine HTTP \(status): \(detail)\(wait)"
    }
    static func retryDelay(_ raw: String?, now: Date) -> Int? {
        guard let raw, raw.utf8.count <= 128 else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let seconds = Int(value), seconds <= 31_536_000 { return seconds }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"; formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return nil }
        let seconds = ceil(date.timeIntervalSince(now))
        guard seconds >= 0, seconds <= 31_536_000 else { return nil }
        return Int(seconds)
    }
}

// Each attempt is only the HTTP inference call. The assistant's tool execution
// loop is outside this boundary and is never replayed by this retry policy.
enum ProviderRetry {
    static func run<T: Sendable>(emit: @escaping @Sendable (AIProgress) -> Void,
                                sleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) },
                                attempt: @escaping @Sendable () async throws -> T) async throws -> T {
        for retry in 0...2 {
            try Task.checkCancellation()
            do { return try await attempt() }
            catch let failure as ProviderFailure {
                guard retry < 2, let delay = failure.retrySeconds else { throw failure }
                if delay > 0 {
                    for remaining in stride(from: delay, through: 1, by: -1) {
                        try Task.checkCancellation()
                        emit(.status("Provider busy; retry \(retry + 1)/2 in \(remaining)s"))
                        try await sleep()
                    }
                }
                try Task.checkCancellation()
                emit(.status("Retrying provider request \(retry + 1)/2"))
            }
        }
        throw AIError.message("Provider retry limit reached")
    }
}
