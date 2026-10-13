import Foundation
import Testing
import Crypto
import KilnKit
import KilnRuntime
import KilnCommands

private let originalAccountKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

@Test func providerAccountOwnershipDoesNotFollowRecreatedSSHUsername() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-account-commands-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try KilnRuntime(stateDirectory: directory)
    let commands = KilnCommands(runtime: runtime)
    try commands.bootstrapIdentity(username: "rootadmin", keys: [originalAccountKey])
    _ = try commands.identities.set(name: "owner", role: "admin", key: originalAccountKey, modules: [])
    let canonical = try KilnIdentityStore.canonicalKey(originalAccountKey)
    let owner = "owner:" + SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    let id = UUID().uuidString.lowercased()
    let metadata = directory.appendingPathComponent("chatgpt-accounts")
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: ["hostID": "urn:uuid:" + UUID().uuidString.lowercased(), "accounts": [["id": id, "owner": owner, "subject": "fixture", "clientID": "oaiapp_fixture", "signedIn": false, "planEnabled": false]]])
    try KilnStateFile.write(data, to: metadata.appendingPathComponent("chatgpt-accounts.json"))
    let original = commands.forIdentity(name: "owner", publicKey: originalAccountKey)
    #expect(await original.execute("ai accounts").text.contains(id))
    var secondBlob = try #require(Data(base64Encoded: originalAccountKey.split(separator: " ")[1].description))
    secondBlob[secondBlob.count - 1] = 1
    let replacementKey = "ssh-ed25519 " + secondBlob.base64EncodedString()
    _ = try commands.identities.set(name: "owner", role: "admin", key: nil, modules: [], revoke: true)
    _ = try commands.identities.set(name: "owner", role: "admin", key: replacementKey, modules: [])
    let replacement = commands.forIdentity(name: "owner", publicKey: replacementKey)
    let listing = await replacement.execute("ai accounts")
    #expect(listing.status == 0)
    #expect(!listing.text.contains(id))
    #expect(await replacement.execute("ai models " + id).status != 0)
    #expect(await original.execute("ai accounts").status != 0)
    await runtime.shutdown()
}

@Test func providerSignInRequiresAdminAndInitializedVaultBeforeOpeningAuthorization() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-login-gates-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try KilnRuntime(stateDirectory: directory)
    let commands = KilnCommands(runtime: runtime)
    try commands.bootstrapIdentity(username: "admin", keys: [originalAccountKey])
    _ = try commands.identities.set(name: "viewer", role: "viewer", key: originalAccountKey, modules: [])
    _ = try commands.identities.set(name: "operator", role: "operator", key: originalAccountKey, modules: [])
    for name in ["viewer", "operator"] {
        let user = commands.forIdentity(name: name, publicKey: originalAccountKey)
        for command in ["ai login chatgpt", "ai accounts", "ai models nonexistent", "ai logout nonexistent"] {
            let denied = await user.execute(command)
            #expect(denied.status != 0)
            #expect(denied.text.contains("Permission denied"))
        }
    }
    let admin = commands.forIdentity(name: "admin", publicKey: originalAccountKey)
    let unavailable = await admin.execute("ai login chatgpt")
    #expect(unavailable.status != 0)
    #expect(!unavailable.text.contains("https://auth.openai.com"))
    #expect(!unavailable.text.contains("Callback:"))
    await runtime.shutdown()
}
