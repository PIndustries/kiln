import Foundation
import KilnAI

extension KilnCommands {
    /// UI context narrows an existing development grant; it never grants access.
    func validateEditorWrite(_ context: [String:String], module: String) async throws {
        guard context["reviewWorker"] == nil else { throw AIError.message("This is a retained proposal review. Stage the proposed file as a local draft, then save or discard it before requesting AI publication.") }
        guard module == context["module"], context["unsaved"] == "false", context["revision"] == "workspace",
              let path = context["path"] else {
            throw AIError.message("Editor changes require the active application and a clean current workspace. Save/discard local edits before AI publishing.")
        }
        let raw = try await webDevelopment.file(module: module, path: path, offset: 0)
        let current = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String:Any]
        guard current?["sha256"] as? String == context["sha256"] else {
            throw AIError.message("Displayed file changed. Refresh the code view before asking for edits.")
        }
    }
}
