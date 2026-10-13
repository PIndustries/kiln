import Foundation
import Testing
import KilnVault
@testable import KilnAI

@Test func grokDeviceCodeAcceptsOnlyOfficialVerificationURL() {
    #expect(GrokCLIAccounts.deviceCode(from: Data("https://accounts.x.ai/oauth2/device?user_code=ABCD-1234\n".utf8)) == "ABCD-1234")
    for text in ["https://evil.invalid/?user_code=ABCD-1234", "https://accounts.x.ai.evil.invalid/oauth2/device?user_code=ABCD-1234", "ABCD-1234", "secret-provider-token"] {
        #expect(GrokCLIAccounts.deviceCode(from: Data(text.utf8)) == nil)
    }
}
@Test func grokCredentialArchiveRejectsSymlinksAndOversize() throws {
    let fm = FileManager.default, home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: home.appendingPathComponent(".grok"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: home) }
    let auth = home.appendingPathComponent(".grok/auth.json")
    try Data(repeating: 65, count: 12_289).write(to: auth)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
    #expect(throws: AIError.self) { try GrokCLIAccounts.readCredential(home: home) }
    try fm.removeItem(at: auth)
    try fm.createSymbolicLink(at: auth, withDestinationURL: home.appendingPathComponent("outside"))
    #expect(throws: AIError.self) { try GrokCLIAccounts.readCredential(home: home) }
}
@Test func grokAccountFixtureEncryptsRefreshAndChecksOwner() async throws {
    guard ProcessInfo.processInfo.environment["KILN_TEST_GROK_SANDBOX"] == "1" else { return }
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("fixture.c"), executable = root.appendingPathComponent("fixture")
    let code = #"""
    #include <stdio.h>
    #include <string.h>
    #include <sys/stat.h>
    #include <unistd.h>
    int main(int argc,char**argv){
      int login=0;for(int i=1;i<argc;i++)if(strcmp(argv[i],"login")==0)login=1;
      mkdir(".grok",0700);FILE*f=fopen(".grok/auth.json","w");if(!f)return 2;
      fputs(login?"opaque-first-credential":"opaque-refreshed-credential",f);fclose(f);chmod(".grok/auth.json",0600);
      if(login){puts("https://accounts.x.ai/oauth2/device?user_code=ABCD-1234");fflush(stdout);sleep(2);}
      else puts("{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"fixture answer\"}}");
      return 0;
    }
    """#
    try Data(code.utf8).write(to: source)
    let compile = Process(); compile.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    compile.arguments = [source.path, "-o", executable.path]; try compile.run(); compile.waitUntilExit()
    #expect(compile.terminationStatus == 0)
    let vault = KilnVault(directory: root.appendingPathComponent("vault"))
    _ = try vault.initialize(keyFile: root.appendingPathComponent("key"))
    let directory = root.appendingPathComponent("accounts")
    let accounts = try GrokCLIAccounts(directory: directory, vault: vault)
    let id = try await accounts.start(owner: "owner", executable: executable)
    // A small flushed device URL must arrive while the process is still alive,
    // not after EOF. The fixture waits two seconds after printing the URL.
    var sawLiveCode = false
    for _ in 0..<100 {
        let status = try await accounts.status(id: id, owner: "owner")
        if status.contains("ABCD-1234") { sawLiveCode = true; break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(sawLiveCode)
    var state = ""
    for _ in 0..<300 {
        state = try await accounts.status(id: id, owner: "owner")
        if state.hasSuffix("ready") || state.hasSuffix("failed") { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(state.hasSuffix("ready"))
    await #expect(throws: AIError.self) { try await accounts.status(id: id, owner: "other") }
    let response = try await accounts.run(account: id, owner: "owner", request: GrokCLIRequest(prompt: "fixture", model: "fixture"), emit: { _ in })
    #expect(response.content == "fixture answer")
    let encoded = try vault.environment(for: "kiln/grok-" + id, bindings: ["AUTH": "grok-account-" + id])["AUTH"]!
    #expect(Data(base64Encoded: encoded) == Data("opaque-refreshed-credential".utf8))
    let metadata = try String(contentsOf: directory.appendingPathComponent("grok-accounts.json"), encoding: .utf8)
    #expect(!metadata.contains("opaque-") && !metadata.contains("ABCD-1234"))
    let sealed = try Data(contentsOf: root.appendingPathComponent("vault/vault.enc"))
    #expect(sealed.range(of: Data("opaque-refreshed-credential".utf8)) == nil)
    let restored = try GrokCLIAccounts(directory: directory, vault: vault)
    #expect(try await restored.status(id: id, owner: "owner").hasSuffix("ready"))
    _ = try await restored.signOut(id: id, owner: "owner")
    #expect(try vault.list() == "Vault is empty.")
    // A stale actor reloads metadata and cannot restore a deleted credential.
    await #expect(throws: AIError.self) {
        try await accounts.run(account: id, owner: "owner", request: GrokCLIRequest(prompt: "fixture", model: "fixture"), emit: { _ in })
    }
    #expect(try await accounts.accounts(owner: "owner") == "No Grok accounts for this identity.")
}

@Test func grokAccountMetadataRejectsSymlinkBeforeReading() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: root) }
    let target = root.appendingPathComponent("outside")
    try Data("[]".utf8).write(to: target)
    try fm.createSymbolicLink(at: root.appendingPathComponent("grok-accounts.json"), withDestinationURL: target)
    #expect(throws: AIError.self) { try GrokCLIAccounts(directory: root, vault: KilnVault(directory: root.appendingPathComponent("vault"))) }
}
