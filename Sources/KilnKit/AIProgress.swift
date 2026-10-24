/// Provider output and factual tool progress, independent of the management transport.
public enum AIProgress: Sendable {
    /// Immutable request configuration selected by the controller, never model prose.
    case provider(AIProviderSnapshot)
    case answer(String)
    case reasoning(String)
    case status(String)
    case snapshot(String)
}
