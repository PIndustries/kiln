import Foundation

/// Typed presentation data only. Actions still pass through normal command
/// authorization and the assistant's session-bound, single-use approval gate.
public struct AIProposalSnapshot: Sendable, Equatable {
    public let id: String
    public let operation: String
    public let module: String
    public let expires: Date
    public init(id: String, operation: String, module: String, expires: Date) {
        self.id = id; self.operation = operation; self.module = module; self.expires = expires
    }
}
public struct AITaskSnapshot: Sendable, Equatable {
    public let id: String
    public let prompt: String
    public let status: String
    public init(id: String, prompt: String, status: String) { self.id = id; self.prompt = prompt; self.status = status }
}
public struct AIProviderSnapshot: Sendable, Equatable, Codable {
    public let provider: String
    public let profile: String
    public let model: String
    public var displayName: String {
        switch provider {
        case "erebine": "Erebine"
        case "ollama": "Ollama"
        case "openai": "OpenAI"
        case "anthropic": "Anthropic"
        case "grok": "Grok"
        case "deepseek": "DeepSeek"
        case "chatgpt": "ChatGPT"
        default: "Unknown"
        }
    }
    public var billingLabel: String {
        switch provider {
        case "chatgpt": "ChatGPT plan"
        case "ollama": "Ollama daemon"
        case "unknown": "Unknown access"
        default: "API credential"
        }
    }
    public var accessLabel: String {
        switch provider {
        case "ollama": "loopback / daemon billing"
        case "chatgpt": "remote / ChatGPT account limits"
        case "unknown": "destination and billing unknown"
        default: "remote / API billing"
        }
    }
    public var label: String { provider + " / " + profile }
    public init(provider: String, profile: String, model: String = "") {
        self.provider = ["erebine", "ollama", "openai", "anthropic", "grok", "deepseek", "chatgpt"].contains(provider) ? provider : "unknown"
        self.profile = !profile.isEmpty && profile.count <= 32 && profile.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }) ? profile : "invalid"
        self.model = model.utf8.count < 256 && model.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value <= 126 }) ? model : "invalid"
    }
}
public struct AIWorkspaceSnapshot: Sendable, Equatable {
    public let proposals: [AIProposalSnapshot]
    public let tasks: [AITaskSnapshot]
    public let error: String?
    public let provider: AIProviderSnapshot?
    public let conversation: String?
    public let contextScope: String?
    public init(proposals: [AIProposalSnapshot] = [], tasks: [AITaskSnapshot] = [], error: String? = nil, provider: AIProviderSnapshot? = nil, conversation: String? = nil, contextScope: String? = nil) {
        self.conversation = conversation; self.contextScope = contextScope
        self.proposals = proposals; self.tasks = tasks; self.error = error; self.provider = provider
    }
}
