import Foundation
import Dispatch

/// Fixed vocabulary only: never send client fields, keys, or parser errors to logs.
enum SSHAdmissionReason: String, Sendable {
    case identityRejected = "identity_rejected"
    case methodRejected = "method_rejected"
    case authenticationBudget = "authentication_budget"
    case authenticationTimeout = "authentication_timeout"
    case preauthenticationBytes = "preauthentication_bytes"
    case connectionCapacity = "connection_capacity"
    case channelCapacity = "channel_capacity"
    case sessionCapacity = "session_capacity"
    case authorizationRevoked = "authorization_revoked"
    case unsupportedChannel = "unsupported_channel"
    case protocolError = "protocol_error"
}

/// One limiter per listener. A blocked stderr cannot accumulate an unbounded queue
/// or block a NIO event loop. Diagnostics are best effort, never an audit log.
final class SSHAdmissionDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "kiln.ssh.diagnostics")
    private let clock: @Sendable () -> TimeInterval
    private let sink: @Sendable (String) -> Void
    private var window: TimeInterval
    private var emitted = 0
    private var pending = 0
    private var suppressed: UInt64 = 0
    init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sink: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }) {
        self.clock = clock; self.sink = sink; self.window = clock()
    }
    func record(_ reason: SSHAdmissionReason, connection: UUID) {
        let line: String? = lock.withLock {
            let now = clock()
            if now - window >= 60 { window = now; emitted = 0 }
            guard emitted < 8, pending < 8 else {
                if suppressed < UInt64.max { suppressed += 1 }
                return nil
            }
            emitted += 1; pending += 1
            let line = "kiln.ssh reason=\(reason.rawValue) connection=\(connection.uuidString.lowercased()) suppressed=\(suppressed)\n"
            suppressed = 0
            return line
        }
        guard let line else { return }
        queue.async { [self] in
            sink(line)
            lock.withLock { pending -= 1 }
        }
    }
    // Tests can wait for bounded queued writes; production never waits for stderr.
    func flush() { queue.sync {} }
}
