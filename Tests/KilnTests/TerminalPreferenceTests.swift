import Foundation
import Testing
import KilnKit
import KilnRuntime
import KilnCommands

private let themeKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

@Test func savedThemeSurvivesNewCommandInstancesAndRuntimeRestart() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try KilnRuntime(stateDirectory: directory)
    let commands = KilnCommands(runtime: runtime)
    try commands.bootstrapIdentity(username: "admin", keys: [themeKey])
    let admin = commands.forIdentity(name: "admin", publicKey: themeKey)
    #expect(try admin.terminalTheme() == TerminalTheme())
    let saved = await admin.execute("theme custom 51 16 255 244")
    #expect(saved.status == 0 && saved.terminalTheme?.accent == 51)
    let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("terminal-preferences"), includingPropertiesForKeys: nil)
    #expect(files.count == 1)
    #expect((try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(try KilnCommands(runtime: runtime).forIdentity(name: "admin", publicKey: themeKey).terminalTheme() == saved.terminalTheme)
    await runtime.shutdown()
    let restored = try KilnRuntime(stateDirectory: directory)
    let reconnect = KilnCommands(runtime: restored).forIdentity(name: "admin", publicKey: themeKey)
    #expect(try reconnect.terminalTheme() == saved.terminalTheme)
    #expect(await reconnect.execute("theme default").status == 0)
    #expect(try reconnect.terminalTheme() == TerminalTheme())
    await restored.shutdown()
}

@Test func savedThemeIsPrivateToIdentityAndKeyAndRevocationApplies() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try KilnRuntime(stateDirectory: directory)
    let local = KilnCommands(runtime: runtime)
    try local.bootstrapIdentity(username: "admin", keys: [themeKey])
    _ = try local.identities.set(name: "reader", role: "viewer", key: themeKey, modules: [])
    let admin = local.forIdentity(name: "admin", publicKey: themeKey)
    let reader = local.forIdentity(name: "reader", publicKey: themeKey)
    #expect(await admin.execute("theme cyan").status == 0)
    #expect(try reader.terminalTheme() == TerminalTheme())
    #expect(await reader.execute("theme amber").status == 0)
    #expect(try admin.terminalTheme().accent == 51)
    #expect(try reader.terminalTheme().accent == 215)
    _ = try local.identities.set(name: "reader", role: "viewer", key: nil, modules: [], revoke: true)
    #expect(await reader.execute("theme green").status != 0)
    #expect(throws: (any Error).self) { try reader.terminalTheme() }
    #expect(throws: (any Error).self) { try local.forIdentity(name: "admin", publicKey: "ssh-ed25519 AAAA").terminalTheme() }
    await runtime.shutdown()
}

@Test func savedThemeRejectsCorruptionAndFailedWritesWithoutClaimingSuccess() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try KilnRuntime(stateDirectory: directory)
    let commands = KilnCommands(runtime: runtime)
    #expect(await commands.execute("theme cyan").status == 0)
    let folder = directory.appendingPathComponent("terminal-preferences")
    let file = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)[0]
    let valid = try Data(contentsOf: file)
    for malformed in [Data("{\"accent\":999,\"background\":0,\"foreground\":252,\"muted\":245}".utf8), Data(repeating: 65, count: 4097)] {
        try malformed.write(to: file)
        #expect(throws: (any Error).self) { try commands.terminalTheme() }
        #expect(await commands.execute("theme").status != 0)
        #expect(await commands.execute("theme default").status == 0)
        #expect(try commands.terminalTheme() == TerminalTheme())
    }
    try valid.write(to: file)
    #expect(await commands.execute("theme custom 46 46 252 245").status != 0)
    #expect(try commands.terminalTheme().accent == 51)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: directory.appendingPathComponent("unrelated"))
    #expect(throws: (any Error).self) { try commands.terminalTheme() }
    try FileManager.default.removeItem(at: folder)
    try Data("blocked".utf8).write(to: folder)
    let failed = await commands.execute("theme green")
    #expect(failed.status != 0 && failed.terminalTheme == nil)
    await runtime.shutdown()
}
