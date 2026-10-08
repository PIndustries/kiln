import Foundation
import Testing
import KilnAI
import KilnVault
import KilnKit

private final class StreamTimes: @unchecked Sendable {
    let lock = NSLock()
    let start = Date()
    var samples: [(Double, Int)] = []
    var reasoningSamples: [(Double, Int)] = []
    func record(_ event: AIProgress) {
        if case .answer(let text) = event {
            lock.lock(); samples.append((Date().timeIntervalSince(start), text.utf8.count)); lock.unlock()
        }
        if case .reasoning(let text) = event {
            lock.lock(); reasoningSamples.append((Date().timeIntervalSince(start), text.utf8.count)); lock.unlock()
        }
    }
    func report() -> String {
        lock.lock(); defer { lock.unlock() }
        let first = samples.first?.0 ?? 0, last = samples.last?.0 ?? 0
        return "STREAM TIMING reasoning_deltas=\(reasoningSamples.count) reasoning_bytes=\(reasoningSamples.reduce(0) { $0+$1.1 }) answer_deltas=\(samples.count) first=\(first)s last=\(last)s span=\(last-first)s bytes=\(samples.reduce(0) { $0+$1.1 })\n" + samples.prefix(12).map { String(format:"%.3fs +%d bytes",$0.0,$0.1) }.joined(separator:"\n")
    }
}
@Test func optionalLiveProviderStreamTiming() async throws {
    guard let path = ProcessInfo.processInfo.environment["KILN_LIVE_STATE"] else { return }
    let directory = URL(fileURLWithPath: path)
    let config = try JSONDecoder().decode(AIConfiguration.self, from: Data(contentsOf: directory.appendingPathComponent("ai.json")))
    let key = try KilnVault(directory: directory).environment(for: "kiln/ai", bindings: ["KEY":config.secret])["KEY"]!
    let times = StreamTimes()
    defer { print(times.report()) }
    _ = try await ErebineClient().stream(configuration: config, key: key, messages: [AIMessage(role:"user",content:"Briefly describe three useful features of a terminal chat interface.")], tools: ProcessInfo.processInfo.environment["KILN_TIMING_TOOLS"] == "1" ? KilnAssistant.tools : []) { times.record($0) }
}
