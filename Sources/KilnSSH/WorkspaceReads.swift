/// Independent SSH lane for registered-source inspection and local draft data.
/// No source mutation, publication or general shell execution is admitted here.
func workspaceReadAllowed(_ parts: [String]) -> Bool {
    guard parts.count >= 3, parts[0] == "web" else { return false }
    switch parts[1] {
    case "browse", "file": return parts.count == 4 || parts.count == 5
    case "workspace", "ide": return parts.count == 4
    case "agents": return parts.count == 3
    case "agent-review": return parts.count == 4 || parts.count == 5
    case "agent-stage": return parts.count == 7
    default: return false
    }
}
