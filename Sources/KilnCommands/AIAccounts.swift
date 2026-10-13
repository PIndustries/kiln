import Foundation
import KilnAI
import KilnVault

/// A single account service shared by every identity-bound command facade.
/// Initialization stays lazy so API-key-only nodes do not create OAuth state.
actor AIAccountServices {
    let directory: URL
    let vault: KilnVault
    private var grokService: GrokCLIAccounts?
    private var chatGPTService: ChatGPTSignIn?
    init(directory: URL, vault: KilnVault) { self.directory = directory; self.vault = vault }
    func grok() throws -> GrokCLIAccounts {
        if let existing = grokService { return existing }
        let service = try GrokCLIAccounts(directory: directory.appendingPathComponent("grok-accounts"), vault: vault)
        grokService = service
        return service
    }
    func chatGPT() throws -> ChatGPTSignIn {
        if let existing = chatGPTService { return existing }
        let service = try ChatGPTSignIn(directory: directory.appendingPathComponent("chatgpt-accounts"), vault: vault)
        chatGPTService = service
        return service
    }
}
