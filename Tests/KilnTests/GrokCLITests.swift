import Foundation
import Testing
@testable import KilnAI

private let grokFixtureLine = Data((#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello ☀"}}"# + "\n").utf8)
private final class GrokCancelProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@Test func grokCLIRequiresExplicitIsolatedSupervisor() async throws {
    let worker = GrokCLIWorker()
    #expect(!worker.available)
    await #expect(throws: AIError.self) {
        try await worker.run(GrokCLIRequest(prompt: "hello", model: "fixture"), emit: { _ in })
    }
}
@Test func grokCLIArgumentsDoNotInterpolateShellOrEnableTools() throws {
    let prompt = "$(touch /tmp/should-not-exist) `command` ; --always-approve"
    let request = try GrokCLIRequest(prompt: prompt, model: "fixture")
    #expect(request.arguments[2] == prompt)
    #expect(!request.arguments.contains("--always-approve"))
    #expect(request.arguments.contains("--no-subagents"))
    let index = try #require(request.arguments.firstIndex(of: "--tools"))
    #expect(request.arguments[index + 1] == "")
    #expect(throws: AIError.self) { try GrokCLIRequest(prompt: "x", model: "m", timeoutSeconds: .infinity) }
}
@Test func grokCLIStreamingHandlesUTF8AndRejectsToolEvents() throws {
    var decoder = GrokCLIStreamDecoder()
    for byte in grokFixtureLine { try decoder.feed(Data([byte]), emit: { _ in }) }
    #expect(try decoder.finish().content == "Hello ☀")
    #expect(throws: AIError.self) {
        try decoder.feed(Data((#"{"sessionUpdate":"tool_call","toolCallId":"1"}"# + "\n").utf8), emit: { _ in })
    }
    var partial = GrokCLIStreamDecoder()
    try partial.feed(Data(grokFixtureLine.dropLast()), emit: { _ in })
    #expect(throws: AIError.self) { try partial.finish() }
    var oversized = GrokCLIStreamDecoder()
    #expect(throws: AIError.self) { try oversized.feed(Data(repeating: 65, count: 262_145), emit: { _ in }) }
}
@Test func grokCLIRequiresExitReceiptAndCancelsSupervisor() async throws {
    let probe = GrokCancelProbe()
    let worker = GrokCLIWorker { _ in
        GrokCLIExecution(output: AsyncThrowingStream { stream in
            stream.yield(.stdout(grokFixtureLine)); stream.yield(.exited(0)); stream.finish()
        }, cancel: { probe.cancel() })
    }
    let result = try await worker.run(GrokCLIRequest(prompt: "hello", model: "fixture"), emit: { _ in })
    #expect(result.content == "Hello ☀" && probe.cancelled)
    let noReceipt = GrokCLIWorker { _ in
        GrokCLIExecution(output: AsyncThrowingStream { stream in
            stream.yield(.stdout(grokFixtureLine)); stream.finish()
        }, cancel: {})
    }
    await #expect(throws: AIError.self) {
        try await noReceipt.run(GrokCLIRequest(prompt: "hello", model: "fixture"), emit: { _ in })
    }
}
@Test func grokCLIDeadlineCancelsWaitingStream() async throws {
    let probe = GrokCancelProbe()
    let worker = GrokCLIWorker { _ in
        let (stream, continuation) = AsyncThrowingStream<GrokCLIOutput, Error>.makeStream()
        return GrokCLIExecution(output: stream, cancel: { probe.cancel(); continuation.finish() })
    }
    await #expect(throws: AIError.self) {
        try await worker.run(GrokCLIRequest(prompt: "hello", model: "fixture", timeoutSeconds: 0.01), emit: { _ in })
    }
    #expect(probe.cancelled)
}
@Test func grokCLICancellationAndDiagnosticLimit() async throws {
    let probe = GrokCancelProbe()
    let worker = GrokCLIWorker { _ in
        let (stream, continuation) = AsyncThrowingStream<GrokCLIOutput, Error>.makeStream()
        return GrokCLIExecution(output: stream, cancel: { probe.cancel(); continuation.finish() })
    }
    let task = Task { try await worker.run(GrokCLIRequest(prompt: "hello", model: "fixture"), emit: { _ in }) }
    // Cancellation is valid before or after supervisor startup.
    task.cancel()
    await #expect(throws: (any Error).self) { try await task.value }
    let diagnostics = GrokCLIWorker { _ in
        GrokCLIExecution(output: AsyncThrowingStream { stream in
            stream.yield(.stderrBytes(65_537)); stream.finish()
        }, cancel: {})
    }
    await #expect(throws: AIError.self) {
        try await diagnostics.run(GrokCLIRequest(prompt: "hello", model: "fixture"), emit: { _ in })
    }
}

@Test func grokSandboxDeniesOutsideReadAndAllowsScratchRead() throws {
    #if os(macOS) || os(Linux)
    // Explicit opt-in because some hosts prohibit sandbox/user namespace creation.
    guard ProcessInfo.processInfo.environment["KILN_TEST_GROK_SANDBOX"] == "1" else { return }
    let fm = FileManager.default
    let scratch = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    let outside = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: scratch); try? fm.removeItem(at: outside) }
    let inside = scratch.appendingPathComponent("allowed.txt")
    try Data("allowed".utf8).write(to: inside); try Data("outside-marker".utf8).write(to: outside)
    func read(_ path: String) throws -> (Int32, String) {
        let p = Process(), pipe = Pipe()
        #if os(Linux)
        p.executableURL = URL(fileURLWithPath: "/usr/bin/bwrap")
        p.arguments = GrokCLISandbox.linuxArguments(executable: "/bin/cat", scratch: scratch.path) + [path.hasPrefix(scratch.path + "/") ? "/workspace/" + URL(fileURLWithPath: path).lastPathComponent : path]
        #else
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-p", GrokCLISandbox.profile(executable: "/bin/cat", scratch: scratch.path), "/bin/cat", path]
        #endif
        p.environment = ["PATH": "/usr/bin:/bin"]
        p.currentDirectoryURL = scratch
        p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: output, as: UTF8.self))
    }
    let permitted = try read(inside.path), denied = try read(outside.path)
    #expect(permitted.0 == 0 && permitted.1 == "allowed", "status=\(permitted.0), output=\(permitted.1)")
    #expect(denied.0 != 0 && !denied.1.contains("outside-marker"))
    #endif
}

@Test func grokCLIProviderErrorsWithholdRawDiagnostics() throws {
    var decoder = GrokCLIStreamDecoder()
    do {
        try decoder.feed(Data((#"{"type":"error","message":"secret-fixture-value"}"# + "\n").utf8), emit: { _ in })
        Issue.record("Expected provider failure")
    } catch {
        #expect(!String(describing: error).contains("secret-fixture-value"))
    }
}

@Test func grokLinuxNamespaceCancellationClosesDescendantPipes() async throws {
    #if os(Linux)
    guard ProcessInfo.processInfo.environment["KILN_TEST_GROK_SANDBOX"] == "1" else { return }
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }
    let source = directory.appendingPathComponent("fixture.c"), executable = directory.appendingPathComponent("fixture")
    // Both parent and child retain stdout. Receiving an exit receipt requires
    // both pipes to close after cancellation, not merely the outer bwrap PID.
    try Data("#include <unistd.h>\n#include <stdio.h>\nint main(){if(fork()==0){while(1)sleep(1);}puts(\"ready\");fflush(stdout);while(1)sleep(1);}".utf8).write(to: source)
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    compiler.arguments = [source.path, "-o", executable.path]
    try compiler.run(); compiler.waitUntilExit()
    #expect(compiler.terminationStatus == 0)
    let execution = try GrokCLISandbox(executable: executable).start(GrokCLIRequest(prompt: "fixture", model: "fixture", timeoutSeconds: 3), apiKey: "fixture")
    defer { execution.cancel() }
    let receipt = try await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask {
            var started = false
            for try await event in execution.output {
                switch event {
                case .stdout: started = true; execution.cancel()
                case .exited(let status): return started && status != 0
                case .stderrBytes: break
                }
            }
            return false
        }
        group.addTask { try await Task.sleep(for: .seconds(5)); return false }
        defer { group.cancelAll() }
        return try await group.next() ?? false
    }
    #expect(receipt)
    #endif
}

@Test func grokLinuxMountsExcludeHostRootAndPrivateCertificateDirectories() {
    let args = GrokCLISandbox.linuxArguments(executable: "/example/grok", scratch: "/example/scratch")
    #expect(args.contains("--unshare-all") && args.contains("--die-with-parent"))
    #expect(!args.contains("/etc/ssl") && !args.contains("/etc/ssl/private") && !args.contains("/etc/pki"))
    for index in args.indices where args[index] == "--ro-bind" || args[index] == "--bind" {
        #expect(args[index + 1] != "/")
    }
}
