/// Provider output and factual tool progress, independent of the management transport.
public enum AIProgress: Sendable {
    case answer(String)
    case reasoning(String)
    case status(String)
    case snapshot(String)
}
