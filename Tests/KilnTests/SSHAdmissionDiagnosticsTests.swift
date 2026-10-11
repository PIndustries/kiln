import XCTest
import Foundation
@testable import KilnSSH

final class SSHAdmissionDiagnosticsTests: XCTestCase {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var time: TimeInterval = 0
        var lines: [String] = []
        func now() -> TimeInterval { lock.withLock { time } }
        func append(_ line: String) { lock.withLock { lines.append(line) } }
    }
    func testRateLimitAndSuppressionSummary() {
        let state = State()
        let diagnostics = SSHAdmissionDiagnostics(clock: { state.now() }, sink: { state.append($0) })
        let id = UUID()
        for _ in 0..<1000 { diagnostics.record(.identityRejected, connection: id) }
        diagnostics.flush()
        XCTAssertEqual(state.lines.count, 8)
        state.time = 60
        diagnostics.record(.authenticationTimeout, connection: id)
        diagnostics.flush()
        XCTAssertEqual(state.lines.count, 9)
        XCTAssertEqual(state.lines.last, "kiln.ssh reason=authentication_timeout connection=\(id.uuidString.lowercased()) suppressed=992\n")
        XCTAssertTrue(state.lines.allSatisfy { $0.utf8.count < 160 })
    }
    func testBlockedSinkBoundsPendingWorkAcrossWindows() {
        let state = State()
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let diagnostics = SSHAdmissionDiagnostics(clock: { state.now() }, sink: { line in
            entered.signal(); gate.wait(); state.append(line)
        })
        diagnostics.record(.connectionCapacity, connection: UUID())
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        for index in 1...1000 {
            state.lock.withLock { state.time = Double(index * 60) }
            diagnostics.record(.protocolError, connection: UUID())
        }
        for _ in 0..<8 { gate.signal() }
        diagnostics.flush()
        XCTAssertEqual(state.lines.count, 8)
    }
}
