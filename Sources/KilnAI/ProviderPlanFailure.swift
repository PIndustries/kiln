import Foundation

/// Reviewed ChatGPT recovery categories only. Never retain provider message text.
struct ProviderPlanFailure: Error, CustomStringConvertible, Sendable {
    private let code: String
    init?(code: String?) {
        guard let code, ["subscription_sharing_usage_limit_exceeded", "subscription_sharing_user_not_eligible",
            "subscription_sharing_unsupported_capability", "subscription_sharing_usage_unavailable",
            "subscription_sharing_user_unavailable", "subscription_sharing_route_not_supported",
            "subscription_sharing_invalid_user", "chatpass_v2_scope_not_authorized",
            "chatpass_v2_invalid_authorization_context"].contains(code) else { return nil }
        self.code = code
    }
    var outcome: AIProviderMetrics.Outcome {
        switch code {
        case "subscription_sharing_usage_limit_exceeded": .quota
        case "subscription_sharing_invalid_user", "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context": .authentication
        default: .rejected
        }
    }
    var description: String {
        switch code {
        case "subscription_sharing_usage_limit_exceeded":
            "ChatGPT plan usage limit reached for this app or account. Manage usage: https://chatgpt.com/settings/usage . No automatic retry or API billing fallback."
        case "subscription_sharing_user_not_eligible":
            "ChatGPT plan usage is unavailable for the selected account, workspace or policy. Repeating sign-in does not establish eligibility."
        case "subscription_sharing_unsupported_capability":
            "This request uses a capability unavailable through ChatGPT plan usage. Change the request before retrying."
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            "ChatGPT plan usage is temporarily unavailable. Credentials are retained; retry later."
        case "subscription_sharing_route_not_supported":
            "This route is unavailable through ChatGPT plan usage. Check the configured Responses integration."
        default:
            "ChatGPT account or plan permission was not accepted. Check the selected account and granted scopes."
        }
    }
}
