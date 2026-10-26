import Foundation
import KilnKit

/// Coalesce deltas before queueing: dropping raw answer deltas loses text.
/// The producer and one queued snapshot retain only the latest bounded output.
final class TaskProgressRelay: @unchecked Sendable {
    let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var output = ""
    private var hasAnswer = false
    private var finished = false
    init() {
        let pair = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream; continuation = pair.continuation
    }
    func send(_ event: AIProgress) {
        lock.withLock {
            guard !finished else { return }
            switch event {
            case .answer(let text):
                guard !text.isEmpty else { return }
                if !hasAnswer { output = "" }
                output = String((output + text).suffix(24000)); hasAnswer = true
            case .snapshot(let text):
                output = String(text.suffix(24000)); hasAnswer = !text.isEmpty
            case .status(let text):
                guard !hasAnswer else { return }
                output = "Activity: " + String(text.prefix(23989)) + "\n"
            case .provider, .reasoning, .source, .work:
                return // Configuration is pinned separately; reasoning stays transient.
            }
            // Yield under the lock so concurrent callbacks cannot reorder snapshots.
            if case .terminated = continuation.yield(output) { finished = true }
        }
    }
    func finish() {
        lock.withLock {
            guard !finished else { return }
            finished = true; continuation.finish()
        }
    }
}
