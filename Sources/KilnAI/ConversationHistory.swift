import Foundation

/// Bound provider context at operator-turn boundaries, keeping tool calls and
/// their results together. This is in-memory context, not a persisted transcript.
struct AIConversationHistory {
    static let messageLimit = 40
    static let byteLimit = 65536
    var encodedBytes: Int? { (try? JSONEncoder().encode(messages))?.count }
    var needsTrimming: Bool { !Self.fits(messages) }
    var messages: [AIMessage] = []
    var turnStarts: [Int] = []

    func recording(_ completed: [AIMessage]) -> Self {
        Self(messages: completed, turnStarts: turnStarts + [messages.count])
    }
    private static func fits(_ messages: [AIMessage]) -> Bool {
        guard messages.count <= messageLimit, let bytes = try? JSONEncoder().encode(messages) else { return false }
        return bytes.count <= byteLimit
    }
    @discardableResult mutating func trim() -> Bool {
        guard needsTrimming else { return false }
        for start in turnStarts.dropFirst() where messages.indices.contains(start) {
            let candidate = Array(messages[start...])
            if Self.fits(candidate) {
                messages = candidate
                turnStarts = turnStarts.filter { $0 >= start }.map { $0 - start }
                return true
            }
        }
        // One oversized turn cannot be split without orphaning tool results.
        messages = []; turnStarts = []
        return true
    }
}
