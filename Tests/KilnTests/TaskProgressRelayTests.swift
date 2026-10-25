import Foundation
import Testing
import KilnKit
@testable import KilnAI

@Test func taskProgressBurstKeepsOneCompleteBoundedSnapshot() async {
    let relay = TaskProgressRelay()
    let pieces = (0..<10000).map { "\($0)," }
    for piece in pieces { relay.send(.answer(piece)) }
    relay.finish()
    var frames: [String] = []
    for await frame in relay.stream { frames.append(frame) }
    #expect(frames == [String(pieces.joined().suffix(24000))])
}

@Test func slowTaskProgressConsumerSkipsFramesWithoutLosingAnswerDeltas() async {
    let relay = TaskProgressRelay()
    var iterator = relay.stream.makeAsyncIterator()
    relay.send(.answer("first "))
    #expect(await iterator.next() == "first ")
    relay.send(.answer("second ")); relay.send(.answer("third"))
    #expect(await iterator.next() == "first second third")
    relay.finish()
    #expect(await iterator.next() == nil)
}

@Test func taskProgressSeparatesActivityFromAnswersAndExcludesReasoning() async {
    let relay = TaskProgressRelay()
    var iterator = relay.stream.makeAsyncIterator()
    relay.send(.status("waiting"))
    relay.send(.reasoning("PRIVATE_REASONING"))
    relay.send(.provider(AIProviderSnapshot(provider: "ollama", profile: "test")))
    #expect(await iterator.next() == "Activity: waiting\n")
    relay.send(.answer("Activity: verified facts"))
    relay.send(.status("must not replace an answer"))
    #expect(await iterator.next() == "Activity: verified facts")
    relay.send(.snapshot("")); relay.send(.status("presenting"))
    #expect(await iterator.next() == "Activity: presenting\n")
    relay.send(.snapshot("replacement")); relay.send(.answer(" answer"))
    relay.finish()
    relay.send(.snapshot("late update"))
    #expect(await iterator.next() == "replacement answer")
    #expect(await iterator.next() == nil)
}

@Test func concurrentTaskProgressCallbacksCannotReorderAccumulatedSnapshots() async {
    let relay = TaskProgressRelay()
    DispatchQueue.concurrentPerform(iterations: 1000) { _ in relay.send(.answer("x")) }
    relay.finish()
    var frames: [String] = []
    for await frame in relay.stream { frames.append(frame) }
    #expect(frames == [String(repeating: "x", count: 1000)])
}

@Test func burstTaskPersistsItsFinalResultAndDoesNotStoreReasoning() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let tasks = AITasks(directory: directory)
    let receipt = try await tasks.submit("burst investigation") { _, _, emit in
        for _ in 0..<2000 { emit(.answer("delta ")); emit(.reasoning("PRIVATE_REASONING")) }
        return "Verified final result."
    }
    let id = String(receipt.split(separator: "\n")[0].dropFirst("Task created: ".count))
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(try await tasks.show(id)).contains("[completed]"), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await tasks.show(id).contains("[completed]"))
    let restored = AITasks(directory: directory)
    let saved = try await restored.show(id)
    #expect(saved.contains("Verified final result.") && !saved.contains("PRIVATE_REASONING"))
}
