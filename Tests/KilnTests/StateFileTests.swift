import Foundation
import Testing
@testable import KilnKit

@Test func stateReplacementIsPrivateAndLeavesNoTemporaryFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("state.json")
    try KilnStateFile.write(Data("first".utf8), to: target)
    try KilnStateFile.write(Data("second".utf8), to: target)
    #expect(try String(contentsOf: target, encoding: .utf8) == "second")
    let permissions = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["state.json"])
    #expect(throws: (any Error).self) { try KilnStateFile.write(Data(), to: directory) }
    #expect(try String(contentsOf: target, encoding: .utf8) == "second")
}

// These inject equivalent filesystem error outcomes, not physical full disks or
// power loss. Every transaction lives in a disposable private test directory.
@Test func stateStorageFaultsPreserveLastCommittedGeneration() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("state.json")
    let old = Data("committed-generation".utf8), replacement = Data("next-generation".utf8)
    for stage in [KilnStateFile.Checkpoint.beforeWrite, .beforeRename] {
        for code in [POSIXErrorCode.ENOSPC, .EACCES, .EIO] {
            try KilnStateFile.write(old, to: target)
            #expect(throws: POSIXError.self) {
                try KilnStateFile.write(replacement, to: target) { checkpoint in
                    if checkpoint == stage { throw POSIXError(code) }
                }
            }
            #expect(try Data(contentsOf: target) == old)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["state.json"])
        }
    }
    // Model a process dying after writing only part of its unique temporary
    // transaction. A later writer must never promote or consume that stale file.
    let orphan = directory.appendingPathComponent(".kiln-write-" + UUID().uuidString)
    try Data("partial-uncommitted".utf8).write(to: orphan)
    #expect(try Data(contentsOf: target) == old)
    try KilnStateFile.write(replacement, to: target)
    #expect(try Data(contentsOf: target) == replacement)
    #expect(try Data(contentsOf: orphan) == Data("partial-uncommitted".utf8))
}

@Test func directoryFlushFailureReportsUncertainCommittedState() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("state.json")
    try KilnStateFile.write(Data("old".utf8), to: target)
    #expect(throws: KilnStateFile.CommitUncertain.self) {
        try KilnStateFile.write(Data("replacement".utf8), to: target) { checkpoint in
            if checkpoint == .directoryFlush { throw POSIXError(.EIO) }
        }
    }
    #expect(try Data(contentsOf: target) == Data("replacement".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["state.json"])
}
