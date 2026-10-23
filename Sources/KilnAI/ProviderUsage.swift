import Foundation
import CoreFoundation

/// Counts supplied by the provider, never inferred from text or used as a bill.
/// Nil means unavailable. Cache/reasoning counts have provider-specific overlap
/// with input/output; they must not be added to a reported total.
public struct AIProviderUsage: Codable, Sendable, Equatable {
    public var inputTokens: UInt64?
    public var outputTokens: UInt64?
    public var totalTokens: UInt64?
    public var cachedInputTokens: UInt64?
    public var cacheWriteInputTokens: UInt64?
    public var reasoningTokens: UInt64?

    public init(inputTokens: UInt64? = nil, outputTokens: UInt64? = nil, totalTokens: UInt64? = nil,
                cachedInputTokens: UInt64? = nil, cacheWriteInputTokens: UInt64? = nil, reasoningTokens: UInt64? = nil) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.totalTokens = totalTokens
        self.cachedInputTokens = cachedInputTokens; self.cacheWriteInputTokens = cacheWriteInputTokens; self.reasoningTokens = reasoningTokens
    }
    var isEmpty: Bool { self == AIProviderUsage() }
    static func count(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        // JSON numbers above the exact integer range cannot be trusted as counts.
        guard value.isFinite, value >= 0, value <= 9_007_199_254_740_991, value.rounded(.towardZero) == value else { return nil }
        return UInt64(value)
    }
    static func responses(_ object: [String: Any]) -> Self {
        let input = object["input_tokens_details"] as? [String: Any] ?? [:]
        let output = object["output_tokens_details"] as? [String: Any] ?? [:]
        return Self(inputTokens: count(object["input_tokens"]), outputTokens: count(object["output_tokens"]),
                    totalTokens: count(object["total_tokens"]), cachedInputTokens: count(input["cached_tokens"]),
                    cacheWriteInputTokens: count(input["cache_write_tokens"]), reasoningTokens: count(output["reasoning_tokens"]))
    }
    static func chatCompletions(_ object: [String: Any]) -> Self {
        let input = object["prompt_tokens_details"] as? [String: Any] ?? [:]
        let output = object["completion_tokens_details"] as? [String: Any] ?? [:]
        return Self(inputTokens: count(object["prompt_tokens"]), outputTokens: count(object["completion_tokens"]),
                    totalTokens: count(object["total_tokens"]), cachedInputTokens: count(object["prompt_cache_hit_tokens"]) ?? count(input["cached_tokens"]),
                    reasoningTokens: count(output["reasoning_tokens"]))
    }
    static func anthropic(_ object: [String: Any]) -> Self {
        Self(inputTokens: count(object["input_tokens"]), outputTokens: count(object["output_tokens"]),
             cachedInputTokens: count(object["cache_read_input_tokens"]), cacheWriteInputTokens: count(object["cache_creation_input_tokens"]))
    }
    /// Anthropic message_delta usage is cumulative, not an increment.
    mutating func update(_ newer: Self) {
        inputTokens = newer.inputTokens ?? inputTokens; outputTokens = newer.outputTokens ?? outputTokens
        totalTokens = newer.totalTokens ?? totalTokens; cachedInputTokens = newer.cachedInputTokens ?? cachedInputTokens
        cacheWriteInputTokens = newer.cacheWriteInputTokens ?? cacheWriteInputTokens; reasoningTokens = newer.reasoningTokens ?? reasoningTokens
    }
    mutating func accumulate(_ other: Self) {
        func sum(_ a: UInt64?, _ b: UInt64?) -> UInt64? {
            guard let b else { return a }; guard let a else { return b }
            let (value, overflow) = a.addingReportingOverflow(b); return overflow ? .max : value
        }
        inputTokens = sum(inputTokens, other.inputTokens); outputTokens = sum(outputTokens, other.outputTokens)
        totalTokens = sum(totalTokens, other.totalTokens); cachedInputTokens = sum(cachedInputTokens, other.cachedInputTokens)
        cacheWriteInputTokens = sum(cacheWriteInputTokens, other.cacheWriteInputTokens); reasoningTokens = sum(reasoningTokens, other.reasoningTokens)
    }
    public var summary: String {
        func show(_ value: UInt64?) -> String { value.map(String.init) ?? "unavailable" }
        return "input=\(show(inputTokens)) output=\(show(outputTokens)) total=\(show(totalTokens)) cached-input=\(show(cachedInputTokens)) cache-write-input=\(show(cacheWriteInputTokens)) reasoning=\(show(reasoningTokens))"
    }
}
