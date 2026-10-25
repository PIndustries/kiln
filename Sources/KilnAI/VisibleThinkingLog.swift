import Foundation
import KilnKit

/// Capture only provider-visible progress, never opaque response items or hidden
/// reasoning fields. A per-turn limit bounds memory even across tool rounds.
final class VisibleThinkingLog: @unchecked Sendable {
    private let lock = NSLock()
    private var output = ""
    private var truncated = false
    var text: String { lock.withLock { output } }
    func receive(_ event: AIProgress) {
        guard case .reasoning(let delta) = event else { return }
        lock.withLock {
            guard !truncated else { return }
            let room = max(0, 131072 - output.count)
            output += delta.prefix(room)
            if delta.count > room {
                output += "\n[Visible thinking limit reached: later output omitted.]"
                truncated = true
            }
        }
    }
}
