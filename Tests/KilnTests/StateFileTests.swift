import Foundation
import Testing
import KilnKit

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
